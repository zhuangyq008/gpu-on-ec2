#!/usr/bin/env bash
# 一键部署: VPC -> NLB/IAM/S3/Secret -> GPU 实例 (vLLM)
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/gpu.sh"
source "$ROOT_DIR/lib/ami.sh"
source "$ROOT_DIR/lib/instance.sh"
source "$ROOT_DIR/lib/keypair.sh"
source "$ROOT_DIR/lib/cidr.sh"

usage() {
  cat <<'EOF'
用法: ./deploy.sh [-y|--yes] [--add] [--no-instance]

交互式完成:
  1. 列出 Region 内 GPU 机型及可用 AZ，选择机型 (默认 g6.12xlarge)
  2. 列出 Deep Learning AMI 并选择
  3. 部署网络栈 (VPC / public+private subnets / NAT / S3 endpoint)
  4. 部署推理栈 (NLB / SG / IAM / API Key / S3 bucket / Logs)
  5. 跨 AZ 抢占 GPU 容量创建实例，注册到 NLB，等待 vLLM 就绪

  -y, --yes   非交互模式，全部使用 config.env 中的默认值 (ALLOWED_CIDRS 必须已设置)
  --add          已有 vLLM 实例时仍新增一台 (默认: 已有实例则只更新栈，不再创建实例)
  --no-instance  只创建网络栈与推理栈，不创建 GPU 实例 (之后用 ./launch-instance.sh 创建)

可重复执行: 中断 (如 CloudShell 会话超时) 后直接重跑，会等待进行中的栈并跳过已完成的步骤。
配置: 编辑 config.env 或用同名环境变量覆盖
EOF
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
  local add=0 no_instance=0 rest=() a
  for a in "$@"; do
    case "$a" in
      --add) add=1 ;;
      --no-instance) no_instance=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  parse_common_flags "${rest[@]+"${rest[@]}"}"
  load_config
  check_prereqs

  # 已有实例且未指定 --add: 只更新栈 (例如修改 ALLOWED_CIDRS)，不再创建实例
  local old="" skip_launch=0
  if stack_ready "$INFERENCE_STACK"; then
    old="$(aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$INSTANCE_ROLE_TAG" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text)"
  fi
  if (( no_instance )); then
    skip_launch=1
    log "--no-instance: 只部署网络栈与推理栈"
  elif [[ -n "$old" ]] && (( ! add )); then
    skip_launch=1
    warn "已存在 vLLM 实例: $old —— 本次只更新栈，不创建新实例 (新增用 --add，替换用 ./launch-instance.sh --replace)"
  fi

  build_gpu_catalog "$INSTANCE_FAMILIES"
  if (( skip_launch )); then
    INSTANCE_TYPE="<不创建>"; AMI_ID="<不创建>"; AMI_NAME=""; SKIP_TYPE_CHECK=1
    AZ_SELECT_TYPE="$DEFAULT_INSTANCE_TYPE"
  else
    log "==== 1/5 选择 GPU 机型 ===="
    SHOW_CAPACITY_SCORE=1 select_instance_type
    check_gpu_memory_fit "$INSTANCE_TYPE"

    log "==== 2/5 选择 Deep Learning AMI ===="
    select_ami
  fi

  resolve_allowed_cidrs
  resolve_azs
  resolve_bucket

  cat >&2 <<EOF

------------------------------ 部署确认 ------------------------------
 Region        : $AWS_REGION        Project: $PROJECT_NAME
 VPC           : $VPC_CIDR  AZ: $AZ_A, $AZ_B  NAT: $NAT_MODE
 Instance      : $INSTANCE_TYPE  (备选: ${FALLBACK_INSTANCE_TYPES:-无})
 AMI           : $AMI_ID  $AMI_NAME
 Model         : $MODEL_ID@$MODEL_REVISION
 Model Bucket  : $MODEL_BUCKET_NAME (新建: $CREATE_BUCKET)
 vLLM          : $VLLM_IMAGE  max_len=$VLLM_MAX_MODEL_LEN
 NLB           : internet-facing TCP:$LISTENER_PORT  来源: $ALLOWED_CIDRS
----------------------------------------------------------------------
EOF
  confirm "确认开始部署?" || exit 0

  log "==== 3/5 部署网络栈 ===="
  deploy_stack "$NETWORK_STACK" "$ROOT_DIR/cfn/network.yaml" \
    "ProjectName=$PROJECT_NAME" "VpcCidr=$VPC_CIDR" "AzA=$AZ_A" "AzB=$AZ_B" "NatMode=$NAT_MODE"

  log "==== 4/5 部署推理栈 ===="
  local cidr_args=()
  mapfile -t cidr_args < <(cidr_slot_params AllowedCidr 10 "$ALLOWED_CIDRS")
  deploy_stack "$INFERENCE_STACK" "$ROOT_DIR/cfn/inference.yaml" \
    "ProjectName=$PROJECT_NAME" \
    "VpcId=$(stack_output "$NETWORK_STACK" VpcId)" \
    "VpcCidr=$(stack_output "$NETWORK_STACK" VpcCidr)" \
    "PublicSubnetIds=$(stack_output "$NETWORK_STACK" PublicSubnetIds)" \
    "${cidr_args[@]}" "ListenerPort=$LISTENER_PORT" \
    "ModelBucketName=$MODEL_BUCKET_NAME" "CreateModelBucket=$CREATE_BUCKET" \
    "ModelS3Prefix=$MODEL_S3_PREFIX" "HfTokenSecretArn=$HF_TOKEN_SECRET_ARN"

  load_stack_outputs
  if (( skip_launch )); then
    print_endpoint_info
    log "查看实例状态: ./status.sh"
    return 0
  fi
  log "==== 5/5 创建 GPU 实例 ===="
  launch_with_fallback
  register_target "$NEW_INSTANCE_ID"
  print_endpoint_info
  wait_healthy "$NEW_INSTANCE_ID" 60 || true
}

main "$@"
