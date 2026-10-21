#!/usr/bin/env bash
# 一键部署: VPC -> NLB/IAM/S3/Secret -> GPU 实例 (可选: vLLM 部署模型 / 裸 GPU 机器 / 不创建)
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/gpu.sh"
source "$ROOT_DIR/lib/ami.sh"
source "$ROOT_DIR/lib/instance.sh"
source "$ROOT_DIR/lib/keypair.sh"
source "$ROOT_DIR/lib/cidr.sh"
source "$ROOT_DIR/lib/iam.sh"
source "$ROOT_DIR/lib/node.sh"

usage() {
  cat <<'EOF'
用法: ./deploy.sh [-y|--yes] [--add | --no-model [--with-nlb] | --no-instance]

交互式完成:
  0. 选择部署内容 (DEPLOY_MODE):
       1) vllm  GPU 实例 + vLLM 部署模型 MODEL_ID (默认 Qwen/Qwen3.5-35B-A3B-FP8)
       2) node  裸 GPU 机器，不部署模型 (先输入节点名 / 是否建 NLB，栈就绪后调用 ./gpu-node.sh create)
       3) infra 只部署网络栈与推理栈，不创建 GPU 机器
  1. 列出 Region 内 GPU 机型及可用 AZ，选择机型 (默认 g6.12xlarge)
  2. 列出 Deep Learning AMI 并选择
  3. 部署网络栈 (VPC / public+private subnets / NAT / S3 endpoint)
  4. 部署推理栈 (NLB / SG / IAM / API Key / S3 bucket / Logs)
  5. 跨 AZ 抢占 GPU 容量创建实例，注册到 NLB，等待 vLLM 就绪
  (node / infra 跳过 1、2、5 步; node 在第 5 步由 gpu-node.sh 选择机型 / AMI / 子网)

  -y, --yes      非交互模式，全部使用 config.env 中的默认值 (ALLOWED_CIDRS 必须已设置;
                 DEPLOY_MODE 为空时部署模型)
  --add          已有 vLLM 实例时仍新增一台 (默认: 已有实例则只更新栈，不再创建实例)
  --no-model     不部署模型，只创建裸 GPU 机器 (同 DEPLOY_MODE=node; 非交互模式节点名为 node1)
  --with-nlb     与 --no-model 一起使用: 为裸 GPU 机器创建对外 NLB
                 (端口 NODE_SERVICE_PORTS，来源 NODE_ALLOWED_CIDRS，非交互模式必须已设置)
  --no-instance  只创建网络栈与推理栈，不创建 GPU 机器 (同 DEPLOY_MODE=infra;
                 之后用 ./launch-instance.sh 部署模型，或 ./gpu-node.sh create 创建裸 GPU 机器)

可重复执行: 中断 (如 CloudShell 会话超时) 后直接重跑，会等待进行中的栈并跳过已完成的步骤。
配置: 编辑 config.env 或用同名环境变量覆盖
EOF
}

MODE_FLAG=""; NODE_WITH_NLB=0

parse_args() {
  local rest=() a
  for a in "$@"; do
    case "$a" in
      --add|--no-model|--no-instance)
        [[ -z "$MODE_FLAG" || "$MODE_FLAG" == "$a" ]] || die "$MODE_FLAG 与 $a 不能同时使用"
        MODE_FLAG="$a" ;;
      --with-nlb) NODE_WITH_NLB=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  parse_common_flags "${rest[@]+"${rest[@]}"}"
}

# 部署内容 DEPLOY_MODE: vllm = GPU 实例 + vLLM 模型; node = 裸 GPU 机器 (不部署模型); infra = 只部署栈
# 优先级: 命令行参数 > DEPLOY_MODE > 交互选择 (非交互模式默认 vllm)
resolve_deploy_mode() {
  local old="$1"
  case "$MODE_FLAG" in
    --add) DEPLOY_MODE=vllm; return ;;
    --no-model) DEPLOY_MODE=node ;;
    --no-instance) DEPLOY_MODE=infra ;;
  esac
  # 已有 vLLM 实例 (例如重跑以修改 ALLOWED_CIDRS) 时不再新增，避免重复创建
  if [[ -n "$old" && ( -z "$DEPLOY_MODE" || "$DEPLOY_MODE" == vllm ) ]]; then
    warn "已存在 vLLM 实例: $old —— 本次只更新栈，不创建新实例 (新增用 --add，替换用 ./launch-instance.sh --replace)"
    DEPLOY_MODE=infra; return
  fi
  [[ -n "$DEPLOY_MODE" ]] && return
  local modes=(vllm node infra) idx
  cat >&2 <<EOF

本次部署内容:
  1) GPU 实例 + 部署模型 $MODEL_ID (vLLM，经 NLB 提供 OpenAI 兼容 API)
  2) 裸 GPU 机器，不部署模型 (同 ./gpu-node.sh create，自行部署 OCR / Embedding 等服务)
  3) 只部署基础设施 (VPC / NLB / IAM / S3)，暂不创建 GPU 机器

EOF
  idx="$(choose_index "请选择部署内容编号" 1 3)"
  DEPLOY_MODE="${modes[idx-1]}"
}

# 裸 GPU 机器的节点名 / 是否创建对外 NLB 在部署确认前确定 (gpu-node.sh 创建后无法再追加 NLB)
# 节点已有实例 (例如 CloudShell 超时后重跑): 交互模式换名，非交互模式只更新栈
resolve_node_options() {
  if [[ "$DEPLOY_MODE" != node ]]; then
    (( ! NODE_WITH_NLB )) || die "--with-nlb 只能用于裸 GPU 机器 (--no-model 或 DEPLOY_MODE=node)"
    return 0
  fi
  local existing ans
  while true; do
    NODE_NAME="$(prompt_default "裸 GPU 机器节点名 (如 ocr / embedding)" node1)"
    validate_node_name "$NODE_NAME"
    existing="$(node_instances "$NODE_NAME")"
    [[ -n "$existing" ]] || break
    if [[ "$ASSUME_YES" == "1" ]]; then
      warn "节点 $NODE_NAME 已有实例 $existing —— 本次只更新栈，不创建新机器 (新增用 ./gpu-node.sh create --name <新节点名>)"
      DEPLOY_MODE=infra; NODE_WITH_NLB=0; return 0
    fi
    warn "节点 $NODE_NAME 已有实例 $existing，请换一个节点名 (重建请先 ./gpu-node.sh delete --name $NODE_NAME)"
  done
  if (( ! NODE_WITH_NLB )); then
    ans="$(prompt_default "是否为裸 GPU 机器创建对外 NLB (端口 $NODE_SERVICE_PORTS)? y/n" n)"
    [[ "$ans" =~ ^[Yy]$ ]] && NODE_WITH_NLB=1
  fi
  return 0
}

# 裸 GPU 机器 NLB 的来源 CIDR 在建栈前确定 (非交互模式缺少时尽早失败)，之后传给 gpu-node.sh
resolve_node_cidrs() {
  [[ "$DEPLOY_MODE" == node ]] && (( NODE_WITH_NLB )) || return 0
  NODE_ALLOWED_CIDRS="$(resolve_cidr_list "$NODE_ALLOWED_CIDRS" "$(node_stack_name "$NODE_NAME")" NodeCidr 5 "GPU 机器 NLB")"
  ok "GPU 机器 NLB 允许来源: $NODE_ALLOWED_CIDRS"
}

# 部署确认中与 GPU 机器相关的行
launch_summary() {
  case "$DEPLOY_MODE" in
    vllm)
      printf ' Instance      : %s  (备选: %s)\n AMI           : %s  %s\n' \
        "$INSTANCE_TYPE" "${FALLBACK_INSTANCE_TYPES:-无}" "$AMI_ID" "$AMI_NAME"
      printf ' Model         : %s@%s\n vLLM          : %s  max_len=%s' \
        "$MODEL_ID" "$MODEL_REVISION" "$VLLM_IMAGE" "$VLLM_MAX_MODEL_LEN" ;;
    node)
      printf ' GPU 机器      : 裸 GPU 机器 %s，不部署模型 (栈就绪后由 gpu-node.sh 选择机型 / AMI / 子网)\n' "$NODE_NAME"
      printf ' GPU 机器 NLB  : %s' \
        "$( (( NODE_WITH_NLB )) && echo "创建，端口 $NODE_SERVICE_PORTS  来源: $NODE_ALLOWED_CIDRS" || echo 不创建)" ;;
    infra)
      printf ' GPU 机器      : 不创建 (之后用 ./launch-instance.sh 部署模型，或 ./gpu-node.sh create)' ;;
  esac
}

# 裸 GPU 机器交给 gpu-node.sh: 机型 / AMI / 子网在其中选择，共用推理栈的 IAM Role
launch_bare_node() {
  local args=(create --name "$NODE_NAME")
  (( NODE_WITH_NLB )) && args+=(--with-nlb)
  [[ "$ASSUME_YES" == "1" ]] && args+=(--yes)
  NODE_ALLOWED_CIDRS="$NODE_ALLOWED_CIDRS" bash "$ROOT_DIR/gpu-node.sh" "${args[@]}"
}

resolve_allowed_cidrs() {
  ALLOWED_CIDRS="$(resolve_cidr_list "$ALLOWED_CIDRS" "$INFERENCE_STACK" AllowedCidr 10 "推理服务 (NLB)")"
  ok "推理服务允许来源: $ALLOWED_CIDRS"
}

# 选择网络栈的两个 AZ: 已存在则沿用; 否则优先选择提供所选机型的 AZ
resolve_azs() {
  if stack_ready "$NETWORK_STACK"; then
    IFS=',' read -r AZ_A AZ_B <<<"$(stack_output "$NETWORK_STACK" AvailabilityZones)"
    log "沿用已有网络栈的 AZ: $AZ_A, $AZ_B"
    local offered
    offered="$(jq -r --arg t "$INSTANCE_TYPE" '.[] | select(.type == $t) | .azs[]' <<<"$GPU_CATALOG_JSON")"
    [[ "${SKIP_TYPE_CHECK:-0}" == "1" ]] || grep -qxE "$AZ_A|$AZ_B" <<<"$offered" \
      || die "$INSTANCE_TYPE 只在 [${offered//$'\n'/ }] 提供，不在现有 VPC 的 AZ 中。请换机型或销毁后重建网络"
    return
  fi
  local azs=() all az
  local az_type="${AZ_SELECT_TYPE:-$INSTANCE_TYPE}"
  mapfile -t azs < <(jq -r --arg t "$az_type" '.[] | select(.type == $t) | .azs[]' <<<"$GPU_CATALOG_JSON")
  if (( ${#azs[@]} < 2 )); then
    all="$(aws ec2 describe-availability-zones --filters Name=zone-type,Values=availability-zone \
            --query 'AvailabilityZones[].ZoneName' --output text)"
    for az in $all; do [[ " ${azs[*]} " == *" $az "* ]] || azs+=("$az"); done
  fi
  AZ_A="${azs[0]}"; AZ_B="${azs[1]}"
  log "网络栈 AZ: $AZ_A, $AZ_B (按 $az_type 的供应情况选择)"
}

resolve_bucket() {
  if stack_ready "$INFERENCE_STACK"; then
    MODEL_BUCKET_NAME="$(stack_output "$INFERENCE_STACK" ModelBucketName)"
    CREATE_BUCKET="$(aws cloudformation describe-stacks --stack-name "$INFERENCE_STACK" \
      --query "Stacks[0].Parameters[?ParameterKey=='CreateModelBucket'].ParameterValue | [0]" --output text)"
    if [[ -n "$MODEL_BUCKET" && "$MODEL_BUCKET" != "$MODEL_BUCKET_NAME" ]]; then
      die "推理栈已使用 bucket $MODEL_BUCKET_NAME，不能改为 $MODEL_BUCKET (请先 ./destroy.sh)"
    fi
    return
  fi
  MODEL_BUCKET_NAME="${MODEL_BUCKET:-${PROJECT_NAME}-models-${ACCOUNT_ID}-${AWS_REGION}}"
  local err rc=0
  err="$(aws s3api head-bucket --bucket "$MODEL_BUCKET_NAME" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    CREATE_BUCKET=false; log "使用已有 bucket: $MODEL_BUCKET_NAME"
  elif grep -q '404\|Not Found' <<<"$err"; then
    CREATE_BUCKET=true;  log "将创建 bucket: $MODEL_BUCKET_NAME"
  else
    die "bucket $MODEL_BUCKET_NAME 无法访问 (可能属于其他账号): $err"
  fi
}

main() {
  parse_args "$@"
  load_config
  check_prereqs

  local old=""
  if stack_ready "$INFERENCE_STACK"; then
    old="$(aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$INSTANCE_ROLE_TAG" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text)"
  fi
  resolve_deploy_mode "$old"
  resolve_node_options
  log "部署内容: $DEPLOY_MODE"

  build_gpu_catalog "$INSTANCE_FAMILIES"
  if [[ "$DEPLOY_MODE" == vllm ]]; then
    log "==== 1/5 选择 GPU 机型 ===="
    SHOW_CAPACITY_SCORE=1 select_instance_type
    check_gpu_memory_fit "$INSTANCE_TYPE"

    log "==== 2/5 选择 Deep Learning AMI ===="
    select_ami
  else
    # 不修改 AMI_ID: 它可能来自环境变量，会被传给 gpu-node.sh
    INSTANCE_TYPE="<不创建>"; SKIP_TYPE_CHECK=1
    AZ_SELECT_TYPE="$DEFAULT_INSTANCE_TYPE"
  fi

  resolve_allowed_cidrs
  resolve_node_cidrs
  resolve_azs
  resolve_bucket

  cat >&2 <<EOF

------------------------------ 部署确认 ------------------------------
 Region        : $AWS_REGION        Project: $PROJECT_NAME
 VPC           : $VPC_CIDR  AZ: $AZ_A, $AZ_B  NAT: $NAT_MODE
$(launch_summary)
 Model Bucket  : $MODEL_BUCKET_NAME (新建: $CREATE_BUCKET)
 GPU IAM Role  : 所有 GPU 机器共用; 额外 S3: ${GPU_S3_BUCKETS:-保持已部署值}
 NLB           : internet-facing TCP:$LISTENER_PORT  来源: $ALLOWED_CIDRS
----------------------------------------------------------------------
EOF
  confirm "确认开始部署?" || exit 0

  log "==== 3/5 部署网络栈 ===="
  deploy_stack "$NETWORK_STACK" "$ROOT_DIR/cfn/network.yaml" \
    "ProjectName=$PROJECT_NAME" "VpcCidr=$VPC_CIDR" "AzA=$AZ_A" "AzB=$AZ_B" "NatMode=$NAT_MODE"

  log "==== 4/5 部署推理栈 ===="
  local cidr_args=() bucket_args=()
  mapfile -t cidr_args < <(cidr_slot_params AllowedCidr 10 "$ALLOWED_CIDRS")
  # GPU_S3_BUCKETS 为空时不传参，保持已部署的 bucket 列表 (含 gpu-node.sh 追加的)
  if [[ -n "$GPU_S3_BUCKETS" ]]; then
    local b removed=()
    for b in $(deployed_gpu_buckets); do [[ " $GPU_S3_BUCKETS " == *" $b "* ]] || removed+=("$b"); done
    if (( ${#removed[@]} > 0 )); then
      warn "GPU_S3_BUCKETS 未包含已授权的 bucket: ${removed[*]} —— 所有 GPU 机器将失去对它们的访问"
      if [[ "$ASSUME_YES" == "1" ]]; then
        [[ "${ALLOW_BUCKET_REMOVAL:-0}" == "1" ]] || die "非交互模式下移除 bucket 需设置 ALLOW_BUCKET_REMOVAL=1"
      else
        confirm "确认移除这些 bucket 权限?" || exit 0
      fi
    fi
    mapfile -t bucket_args < <(gpu_bucket_params "$GPU_S3_BUCKETS")
  fi
  deploy_stack "$INFERENCE_STACK" "$ROOT_DIR/cfn/inference.yaml" \
    "ProjectName=$PROJECT_NAME" \
    "VpcId=$(stack_output "$NETWORK_STACK" VpcId)" \
    "VpcCidr=$(stack_output "$NETWORK_STACK" VpcCidr)" \
    "PublicSubnetIds=$(stack_output "$NETWORK_STACK" PublicSubnetIds)" \
    "${cidr_args[@]}" "${bucket_args[@]+"${bucket_args[@]}"}" "ListenerPort=$LISTENER_PORT" \
    "ModelBucketName=$MODEL_BUCKET_NAME" "CreateModelBucket=$CREATE_BUCKET" \
    "ModelS3Prefix=$MODEL_S3_PREFIX" "HfTokenSecretArn=$HF_TOKEN_SECRET_ARN"

  load_stack_outputs
  case "$DEPLOY_MODE" in
    vllm)
      log "==== 5/5 创建 GPU 实例 ===="
      launch_with_fallback
      register_target "$NEW_INSTANCE_ID"
      print_endpoint_info
      wait_healthy "$NEW_INSTANCE_ID" 60 || true ;;
    node)
      log "==== 5/5 创建裸 GPU 机器 (./gpu-node.sh create) ===="
      launch_bare_node ;;
    infra)
      print_endpoint_info
      log "查看实例状态: ./status.sh  部署模型: ./launch-instance.sh  裸 GPU 机器: ./gpu-node.sh create" ;;
  esac
}

main "$@"
