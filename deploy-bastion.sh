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
source "$ROOT_DIR/lib/bastion.sh"

usage() {
  cat <<'EOF'
用法: ./deploy-bastion.sh [-y|--yes]
  创建或更新运维跳板机。可重复执行 (修改 SSH_ALLOWED_CIDRS / OPS_EXTRA_BUCKETS 后重跑即可更新)
  -y, --yes   非交互模式 (SSH_ALLOWED_CIDRS 必须已配置或已部署)
  机型: BASTION_INSTANCE_TYPE 为空时交互选择 (x86_64 / arm64，含价格与场景建议)，如
        BASTION_INSTANCE_TYPE=t4g.small ./deploy-bastion.sh
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

# 共用跳板机: 同 VPC 的已有 gpu-node 栈补上 "跳板机 SSH" 规则 (在跳板机之前创建的节点)
sync_node_stacks() {
  local sg vpc s cur svpc
  sg="$(stack_output "$BASTION_STACK" BastionSecurityGroupId)"
  vpc="$(stack_output "$NETWORK_STACK" VpcId)"
  for s in $(aws cloudformation describe-stacks \
               --query "Stacks[?starts_with(StackName,'$PROJECT_NAME-node-')].StackName" --output text); do
    stack_ready "$s" || { warn "跳过 $s ($(stack_status "$s"))"; continue; }
    svpc="$(aws cloudformation describe-stacks --stack-name "$s" \
      --query "Stacks[0].Parameters[?ParameterKey=='VpcId'].ParameterValue | [0]" --output text)"
    cur="$(aws cloudformation describe-stacks --stack-name "$s" \
      --query "Stacks[0].Parameters[?ParameterKey=='BastionSecurityGroupId'].ParameterValue | [0]" --output text)"
    if [[ "$svpc" != "$vpc" ]]; then
      log "节点栈 $s 在其他 VPC ($svpc)，跳板机只能经 SSM 访问，跳过"
      continue
    fi
    [[ "$cur" == "$sg" ]] && continue
    log "节点栈 $s: 放行跳板机 SSH"
    # 沿用已部署的模板与其余参数，只修改 BastionSecurityGroupId (避免新版模板意外变更节点资源)
    local params
    params="$(aws cloudformation describe-stacks --stack-name "$s" --output json \
      --query 'Stacks[0].Parameters[].ParameterKey' \
      | jq -c --arg sg "$sg" 'map(if . == "BastionSecurityGroupId"
                                  then {ParameterKey: ., ParameterValue: $sg}
                                  else {ParameterKey: ., UsePreviousValue: true} end)')"
    aws cloudformation update-stack --stack-name "$s" --use-previous-template \
      --capabilities CAPABILITY_NAMED_IAM --parameters "$params" >/dev/null \
      || die "更新节点栈 $s 失败"
    aws cloudformation wait stack-update-complete --stack-name "$s" || die "节点栈 $s 更新失败，请查看栈事件"
    ok "节点栈 $s 已放行跳板机 SSH"
  done
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
   gpu-list                                    # 列出本项目 / 同 VPC 的所有 GPU 机器 (含私网 IP)
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

  # 公有子网候选: 已部署的子网优先 (避免无谓替换)，其余按网络栈顺序; 容量不足时依次换 AZ
  local all=() candidates=() deployed_subnet="" s
  IFS=',' read -ra all <<<"$(stack_output "$NETWORK_STACK" PublicSubnetIds)"
  stack_ready "$BASTION_STACK" && deployed_subnet="$(aws cloudformation describe-stacks --stack-name "$BASTION_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='PublicSubnetId'].ParameterValue | [0]" --output text)"
  [[ -n "$deployed_subnet" && " ${all[*]} " == *" $deployed_subnet "* ]] && candidates+=("$deployed_subnet")
  for s in "${all[@]}"; do [[ " ${candidates[*]} " == *" $s "* ]] || candidates+=("$s"); done
  local -A subnet_az=()
  while read -r s az; do subnet_az[$s]="$az"; done < <(aws ec2 describe-subnets --subnet-ids "${candidates[@]}" \
    --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text)
  local azs=()
  for s in "${candidates[@]}"; do azs+=("${subnet_az[$s]}"); done
  select_bastion_type "${azs[@]}"

  cat >&2 <<EOF

------------------------------ 跳板机确认 ------------------------------
 Region     : $AWS_REGION   Project: $PROJECT_NAME
 机型       : $BASTION_INSTANCE_TYPE ($BASTION_ARCH, Amazon Linux 2023)  根卷: ${BASTION_ROOT_VOLUME_GB}GB
 子网       : ${candidates[0]} (${subnet_az[${candidates[0]}]}, public) + EIP，容量不足时依次尝试其他 AZ
 SSH key    : $OPS_KEY_NAME $([[ -z "$KEY_NAME" ]] && echo "(不存在时自动创建)")
 SSH 来源   : $SSH_ALLOWED_CIDRS
 S3 读写    : $OPS_BUCKETS_DISPLAY
------------------------------------------------------------------------
EOF
  confirm "确认创建/更新跳板机?" || exit 0

  ensure_ops_key_pair

  local cidr_args=()
  mapfile -t cidr_args < <(cidr_slot_params SshCidr 5 "$SSH_ALLOWED_CIDRS")
  local done_ok=0
  for s in "${candidates[@]}"; do
    type_offered_in "$BASTION_INSTANCE_TYPE" "${subnet_az[$s]}" || { log "$BASTION_INSTANCE_TYPE 在 ${subnet_az[$s]} 无供应，跳过"; continue; }
    log "尝试在 ${subnet_az[$s]} ($s) 部署跳板机"
    DEPLOY_STACK_NO_DIE=1 deploy_stack "$BASTION_STACK" "$ROOT_DIR/cfn/bastion.yaml" \
      "ProjectName=$PROJECT_NAME" \
      "VpcId=$(stack_output "$NETWORK_STACK" VpcId)" \
      "PublicSubnetId=$s" \
      "GpuInstanceSecurityGroupId=$INSTANCE_SG_ID" \
      "InstanceType=$BASTION_INSTANCE_TYPE" "Arch=$BASTION_ARCH" "ImageId=$(bastion_ami_param)" \
      "RootVolumeGB=$BASTION_ROOT_VOLUME_GB" \
      "KeyName=$OPS_KEY_NAME" \
      "OpsBucketArns=$OPS_BUCKET_ARNS" "OpsObjectArns=$OPS_OBJECT_ARNS" \
      "ModelBucketName=$MODEL_BUCKET_NAME" "ApiKeySecretArn=$API_KEY_SECRET_ARN" \
      "LogGroupName=$LOG_GROUP_NAME" \
      "${cidr_args[@]}" && { done_ok=1; break; }
    grep -qiE 'insufficient|sufficient .*capacity' <<<"$DEPLOY_STACK_ERROR" \
      || die "栈 $BASTION_STACK 部署失败 (非容量问题，见上方原因)"
    warn "${subnet_az[$s]} 的 $BASTION_INSTANCE_TYPE 容量不足，换下一个 AZ 重试"
  done
  (( done_ok )) || die "所有公有子网的 $BASTION_INSTANCE_TYPE 都容量不足，请换机型 (BASTION_INSTANCE_TYPE=...) 后重试"

  sync_node_stacks

  local nokey
  nokey="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$INSTANCE_ROLE_TAG,gpu-node" \
              "Name=instance-state-name,Values=pending,running,stopped" \
    --query 'Reservations[].Instances[?KeyName==null].InstanceId' --output text)"
  if [[ -n "$nokey" ]]; then
    warn "GPU 实例 $nokey 创建时未挂载 SSH key，只能经 SSM 登录；"
    warn "需要 SSH 时执行 ./launch-instance.sh --replace 重建 (新实例会自动挂载 $OPS_KEY_NAME)"
  fi
  print_bastion_info
}

main "$@"
