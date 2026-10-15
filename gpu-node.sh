#!/usr/bin/env bash
# 独立创建 / 列出 / 删除裸 GPU 机器 (不部署任何模型)，供客户自行部署 OCR、Embedding 等服务
#   - IAM Role: SSM + 指定 S3 bucket 读写 + ECR 只读
#   - 交互选择机型 / DLAMI / 子网 (默认私有子网)，跨 AZ 抢占 GPU 容量
#   - 初始化: NVMe RAID0 -> /mnt/nvme、Docker 数据目录迁到 NVMe、挂载运维 SSH key
#   - 可选 --with-nlb: 独立 internet-facing NLB，每个服务端口一个 TCP listener
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/gpu.sh"
source "$ROOT_DIR/lib/ami.sh"
source "$ROOT_DIR/lib/instance.sh"
source "$ROOT_DIR/lib/keypair.sh"
source "$ROOT_DIR/lib/cidr.sh"
source "$ROOT_DIR/lib/subnet.sh"
source "$ROOT_DIR/lib/node.sh"

usage() {
  cat <<'EOF'
用法:
  ./gpu-node.sh create [--name <节点名>] [--with-nlb] [-y]   创建裸 GPU 机器
  ./gpu-node.sh list                                        列出本项目的 GPU 机器
  ./gpu-node.sh delete --name <节点名> [-y]                  终止机器并删除其 IAM / SG / NLB

  --name       节点名 (小写字母/数字/-，如 ocr、embedding)，对应栈 <project>-node-<节点名>
  --with-nlb   创建独立的 internet-facing NLB，对外暴露 NODE_SERVICE_PORTS (来源 NODE_ALLOWED_CIDRS)
  -y, --yes    非交互模式

常用配置 (config.env 或环境变量): NODE_SERVICE_PORTS NODE_S3_BUCKETS NODE_ALLOWED_CIDRS
  DEFAULT_INSTANCE_TYPE AMI_ID NODE_SUBNET_ID NODE_DOCKER_ON_NVME NODE_IMDS_HOP_LIMIT
EOF
}

NODE_NAME=""; WITH_NLB=0

parse_args() {
  local rest=()
  while (( $# > 0 )); do
    case "$1" in
      --name) NODE_NAME="${2:-}"; shift ;;
      --with-nlb) WITH_NLB=1 ;;
      *) rest+=("$1") ;;
    esac
    shift
  done
  parse_common_flags "${rest[@]+"${rest[@]}"}"
}

cmd_create() {
  [[ -n "$NODE_NAME" ]] || NODE_NAME="$(prompt_default "节点名 (如 ocr / embedding)" "node1")"
  validate_node_name "$NODE_NAME"
  NODE_STACK="$(node_stack_name "$NODE_NAME")"

  local existing
  existing="$(node_instances "$NODE_NAME")"
  [[ -z "$existing" ]] || die "节点 $NODE_NAME 已有实例 $existing。如需重建请先 ./gpu-node.sh delete --name $NODE_NAME"

  log "==== 1/5 选择 GPU 机型 ===="
  build_gpu_catalog "$INSTANCE_FAMILIES"
  SHOW_CAPACITY_SCORE=1 select_instance_type

  log "==== 2/5 选择 Deep Learning AMI ===="
  select_ami

  log "==== 3/5 选择子网 ===="
  build_subnet_catalog
  select_subnet "$INSTANCE_TYPE"
  NODE_BASTION_SG="$(bastion_sg_for_vpc "$NODE_VPC_ID")"

  local nlb_azs=""
  if [[ "$WITH_NLB" == "1" ]]; then
    local nlb
    nlb="$(nlb_public_subnets)"
    NODE_NLB_SUBNETS="${nlb%% *}"; nlb_azs="${nlb#* }"
    [[ -n "$NODE_NLB_SUBNETS" ]] || die "VPC $NODE_VPC_ID 中没有公有子网，无法创建 internet-facing NLB"
    [[ " $nlb_azs " == *" $NODE_AZ "* ]] \
      || die "所选子网的 AZ $NODE_AZ 没有公有子网，NLB 无法转发到该 AZ 的实例。请换子网 (NLB 可用 AZ: $nlb_azs)"
    NODE_ALLOWED_CIDRS="$(resolve_cidr_list "$NODE_ALLOWED_CIDRS" "$NODE_STACK" NodeCidr 5 "GPU 机器 NLB")"
  fi
  resolve_node_buckets

  cat >&2 <<EOF

------------------------------ GPU 机器确认 ------------------------------
 节点 / 栈   : $NODE_NAME / $NODE_STACK
 机型        : $INSTANCE_TYPE  (备选: ${FALLBACK_INSTANCE_TYPES:-无})
 AMI         : $AMI_ID  $AMI_NAME
 子网        : $NODE_SUBNET_ID ($NODE_AZ, $([[ "$NODE_SUBNET_PUBLIC" == "true" ]] && echo 公有 || echo 私有))  VPC $NODE_VPC_ID $NODE_VPC_CIDR
 容量回退    : $([[ "$NODE_SUBNET_FALLBACK" == "1" ]] && echo "同 VPC 其他 AZ 的同类型子网" || echo "关闭")
 IAM         : SSM + ECR 只读 + S3 读写 [$NODE_BUCKETS]
 服务端口    : $NODE_SERVICE_PORTS (VPC 内 $NODE_VPC_CIDR)$([[ -n "$NODE_BASTION_SG" ]] && echo "，跳板机 SSH")
 NLB         : $([[ "$WITH_NLB" == "1" ]] && echo "internet-facing，来源 $NODE_ALLOWED_CIDRS" || echo "不创建")
 根卷 / IMDS : ${NODE_ROOT_VOLUME_GB}GB gp3 / hop limit $NODE_IMDS_HOP_LIMIT   Docker on NVMe: $NODE_DOCKER_ON_NVME$([[ "$NODE_IMDS_HOP_LIMIT" == "2" ]] && printf '\n              (hop limit 2: 容器内可使用实例角色访问 S3/ECR；不需要时设 NODE_IMDS_HOP_LIMIT=1)')
--------------------------------------------------------------------------
EOF
  confirm "确认创建?" || exit 0

  log "==== 4/5 部署节点栈 (IAM / SG$([[ "$WITH_NLB" == "1" ]] && echo " / NLB")) ===="
  local params=()
  mapfile -t params < <(node_stack_params)
  deploy_stack "$NODE_STACK" "$ROOT_DIR/cfn/gpu-node.yaml" "${params[@]}"

  log "==== 5/5 创建 GPU 实例 ===="
  configure_node_launch "$nlb_azs"
  launch_with_fallback
  [[ "$WITH_NLB" == "1" ]] && register_node_targets "$NEW_INSTANCE_ID"
  log "实例启动后约 3-5 分钟完成初始化 (NVMe / Docker)，进度: SSM 登录后 sudo tail -f /var/log/gpu-node-userdata.log"
  print_node_info "$NEW_INSTANCE_ID"
}

# shellcheck disable=SC2016  # JMESPath 字面量
cmd_list() {
  log "GPU 机器 (Project=$PROJECT_NAME, Role=$NODE_ROLE_TAG):"
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$NODE_ROLE_TAG" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Node`]|[0].Value,InstanceId,InstanceType,Placement.AvailabilityZone,PrivateIpAddress,State.Name,LaunchTime]' \
    --output table >&2
  log "节点栈:"
  aws cloudformation describe-stacks \
    --query "Stacks[?starts_with(StackName,'$PROJECT_NAME-node-')].[StackName,StackStatus,Outputs[?OutputKey=='NlbDnsName']|[0].OutputValue]" \
    --output table >&2
}

cmd_delete() {
  [[ -n "$NODE_NAME" ]] || die "请用 --name 指定要删除的节点"
  validate_node_name "$NODE_NAME"
  NODE_STACK="$(node_stack_name "$NODE_NAME")"
  local ids
  ids="$(node_instances "$NODE_NAME" "pending,running,stopping,stopped,shutting-down")"
  [[ -n "$ids" || "$(stack_status "$NODE_STACK")" != "NOT_FOUND" ]] || die "节点 $NODE_NAME 不存在"
  warn "将终止实例 [${ids:-无}] 并删除栈 $NODE_STACK (IAM Role / SG / NLB)。/mnt/nvme 上的数据会丢失"
  confirm "确认删除节点 $NODE_NAME?" || exit 0
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086  # 多个实例 ID
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    # shellcheck disable=SC2086
    wait_terminated $ids
  fi
  if [[ "$(stack_status "$NODE_STACK")" != "NOT_FOUND" ]]; then
    aws cloudformation delete-stack --stack-name "$NODE_STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$NODE_STACK" || die "删除栈 $NODE_STACK 失败"
  fi
  ok "节点 $NODE_NAME 已删除"
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift
  case "$cmd" in
    create|list|delete) ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知命令: $cmd (create / list / delete)" ;;
  esac
  parse_args "$@"
  load_config
  check_prereqs
  "cmd_$cmd"
}

main "$@"
