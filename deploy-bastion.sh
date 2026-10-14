#!/usr/bin/env bash
# 创建 / 更新运维跳板机 (需先运行 ./deploy.sh 创建网络栈与推理栈)
#   - public subnet + EIP，SSH (SSH_ALLOWED_CIDRS) 与 SSM 均可登录
#   - 可 SSH / SSM 登录 GPU 实例，直连 vLLM 8000 端口
#   - 读写模型 bucket 及 OPS_EXTRA_BUCKETS
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/instance.sh"
source "$ROOT_DIR/lib/keypair.sh"
source "$ROOT_DIR/lib/cidr.sh"

usage() {
  cat <<'EOF'
用法: ./deploy-bastion.sh [-y|--yes]
  创建或更新运维跳板机。可重复执行 (修改 SSH_ALLOWED_CIDRS / OPS_EXTRA_BUCKETS 后重跑即可更新)
  -y, --yes   非交互模式 (SSH_ALLOWED_CIDRS 必须已配置或已部署)
EOF
}

# 跳板机可访问的 bucket: 模型 bucket + OPS_EXTRA_BUCKETS -> 两个逗号分隔的 ARN 列表
build_bucket_arns() {
  local partition b buckets=("$MODEL_BUCKET_NAME") bucket_arns=() object_arns=()
  partition="$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)"
  for b in $OPS_EXTRA_BUCKETS; do
    [[ " ${buckets[*]} " == *" $b "* ]] || buckets+=("$b")
  done
  for b in "${buckets[@]}"; do
    bucket_arns+=("arn:$partition:s3:::$b")
    object_arns+=("arn:$partition:s3:::$b/*")
  done
  OPS_BUCKET_ARNS="$(IFS=,; echo "${bucket_arns[*]}")"
  OPS_OBJECT_ARNS="$(IFS=,; echo "${object_arns[*]}")"
  OPS_BUCKETS_DISPLAY="${buckets[*]}"
}

print_bastion_info() {
  local ip iid pem
  ip="$(stack_output "$BASTION_STACK" BastionPublicIp)"
  iid="$(stack_output "$BASTION_STACK" BastionInstanceId)"
  pem="$(ops_key_path)"
  [[ -n "$KEY_NAME" ]] && pem="<$KEY_NAME 对应的私钥>"
  cat >&2 <<EOF

================================ 运维跳板机 ================================
 Instance  : $iid   公网 IP (EIP): $ip
 SSH 登录  : ssh -i $pem ec2-user@$ip
 SSM 登录  : aws ssm start-session --region $AWS_REGION --target $iid
 S3 读写   : $OPS_BUCKETS_DISPLAY

 登录跳板机后:
   gpu-list                                    # 列出 GPU 实例 (含私网 IP)
   ssh ec2-user@<GPU私网IP>                    # 需先把私钥带到跳板机，或在本机用下面的 -J 方式
   aws ssm start-session --target <GPU实例ID>  # 不需要 key
   curl -H "Authorization: Bearer \$(vllm-key)" http://<GPU私网IP>:8000/v1/models
   aws s3 ls s3://\$MODEL_BUCKET/

 本机经跳板机直接登录 GPU 实例 (实例需挂载该 key，即本脚本之后创建的 GPU 实例):
   ssh -i $pem -J ec2-user@$ip ec2-user@<GPU私网IP>
   (Ubuntu DLAMI 的用户名为 ubuntu)
============================================================================
EOF
}

main() {
  parse_common_flags "$@"
  load_config
  check_prereqs
  load_stack_outputs

  SSH_ALLOWED_CIDRS="$(resolve_cidr_list "$SSH_ALLOWED_CIDRS" "$BASTION_STACK" SshCidr 5 "跳板机 SSH")"
  ok "SSH 允许来源: $SSH_ALLOWED_CIDRS"
  build_bucket_arns

  local public_subnet
  public_subnet="$(stack_output "$NETWORK_STACK" PublicSubnetIds | cut -d, -f1)"

  cat >&2 <<EOF

------------------------------ 跳板机确认 ------------------------------
 Region     : $AWS_REGION   Project: $PROJECT_NAME
 机型       : $BASTION_INSTANCE_TYPE (Amazon Linux 2023)  根卷: ${BASTION_ROOT_VOLUME_GB}GB
 子网       : $public_subnet (public) + EIP
 SSH key    : $OPS_KEY_NAME $([[ -z "$KEY_NAME" ]] && echo "(不存在时自动创建)")
 SSH 来源   : $SSH_ALLOWED_CIDRS
 S3 读写    : $OPS_BUCKETS_DISPLAY
------------------------------------------------------------------------
EOF
  confirm "确认创建/更新跳板机?" || exit 0

  ensure_ops_key_pair

  local cidr_args=()
  mapfile -t cidr_args < <(cidr_slot_params SshCidr 5 "$SSH_ALLOWED_CIDRS")
  deploy_stack "$BASTION_STACK" "$ROOT_DIR/cfn/bastion.yaml" \
    "ProjectName=$PROJECT_NAME" \
    "VpcId=$(stack_output "$NETWORK_STACK" VpcId)" \
    "PublicSubnetId=$public_subnet" \
    "GpuInstanceSecurityGroupId=$INSTANCE_SG_ID" \
    "InstanceType=$BASTION_INSTANCE_TYPE" "RootVolumeGB=$BASTION_ROOT_VOLUME_GB" \
    "KeyName=$OPS_KEY_NAME" \
    "OpsBucketArns=$OPS_BUCKET_ARNS" "OpsObjectArns=$OPS_OBJECT_ARNS" \
    "ModelBucketName=$MODEL_BUCKET_NAME" "ApiKeySecretArn=$API_KEY_SECRET_ARN" \
    "LogGroupName=$LOG_GROUP_NAME" \
    "${cidr_args[@]}"

  local nokey
  nokey="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$INSTANCE_ROLE_TAG" \
              "Name=instance-state-name,Values=pending,running,stopped" \
    --query 'Reservations[].Instances[?KeyName==null].InstanceId' --output text)"
  if [[ -n "$nokey" ]]; then
    warn "GPU 实例 $nokey 创建时未挂载 SSH key，只能经 SSM 登录；"
    warn "需要 SSH 时执行 ./launch-instance.sh --replace 重建 (新实例会自动挂载 $OPS_KEY_NAME)"
  fi
  print_bastion_info
}

main "$@"
