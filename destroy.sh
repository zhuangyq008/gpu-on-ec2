#!/usr/bin/env bash
# 销毁全部资源: GPU 实例 -> 推理栈 -> 网络栈
# 模型权重 S3 bucket 与日志之外的资源都会被删除; bucket 默认保留 (DeletionPolicy: Retain)
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

usage() { echo "用法: ./destroy.sh [-y|--yes]"; }

delete_stack() {
  local stack="$1"
  [[ "$(stack_status "$stack")" == "NOT_FOUND" ]] && { log "栈 $stack 不存在，跳过"; return; }
  log "删除栈 $stack ..."
  aws cloudformation delete-stack --stack-name "$stack"
  aws cloudformation wait stack-delete-complete --stack-name "$stack" || die "删除栈 $stack 失败，请在控制台查看事件"
  ok "已删除 $stack"
}

# GPU 实例终止常超过 10 分钟 (CLI waiter 的默认上限)，这里自行轮询，最长 30 分钟
wait_terminated() {
  local start left
  start="$(date +%s)"
  log "等待实例终止: $* (GPU 实例通常需要 5-15 分钟)"
  while true; do
    left="$(aws ec2 describe-instances --instance-ids "$@" \
      --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId" --output text)"
    [[ -z "$left" ]] && return 0
    (( $(date +%s) - start < 1800 )) || die "等待超时，仍未终止: $left (稍后重新执行 ./destroy.sh)"
    sleep 20
  done
}

main() {
  parse_common_flags "$@"
  load_config
  require_cmds aws jq

  local ids bucket="" secret=""
  ids="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=vllm" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  [[ "$(stack_status "$INFERENCE_STACK")" != "NOT_FOUND" ]] && \
    { bucket="$(stack_output "$INFERENCE_STACK" ModelBucketName 2>/dev/null || true)"
      secret="$(stack_output "$INFERENCE_STACK" ApiKeySecretArn 2>/dev/null || true)"; }

  cat >&2 <<EOF
将在 $AWS_REGION 删除:
  GPU 实例   : ${ids:-无}
  CFN 栈     : $BASTION_STACK (如存在), $INFERENCE_STACK, $NETWORK_STACK
  保留       : S3 bucket ${bucket:-无} (模型权重)
EOF
  confirm "确认删除?" || exit 0

  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    # shellcheck disable=SC2086  # 需要按空格拆分为多个实例 ID
    wait_terminated $ids
    ok "实例已终止"
  fi
  # 跳板机栈在 GPU 实例 SG 上添加了规则，必须先于推理栈删除
  delete_stack "$BASTION_STACK"
  delete_stack "$INFERENCE_STACK"
  # CFN 删除 secret 默认进入 30 天恢复期，同名重建会冲突，这里立即彻底删除
  if [[ -n "$secret" && "$secret" != "None" ]]; then
    aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery >/dev/null 2>&1 || true
  fi
  delete_stack "$NETWORK_STACK"

  if [[ -z "$KEY_NAME" ]] && aws ec2 describe-key-pairs --key-names "$OPS_KEY_NAME" >/dev/null 2>&1; then
    cat >&2 <<EOF

运维 key pair $OPS_KEY_NAME 已保留 (下次部署复用)。如需删除:
  aws ec2 delete-key-pair --region $AWS_REGION --key-name $OPS_KEY_NAME && rm -f $SSH_KEY_DIR/$OPS_KEY_NAME.pem
EOF
  fi

  if [[ -n "$bucket" && "$bucket" != "None" ]]; then
    cat >&2 <<EOF

模型权重 bucket 已保留，下次部署会自动复用。如需彻底删除 (bucket 开启了 versioning，需要删除所有版本):
  aws s3api list-object-versions --bucket $bucket --region $AWS_REGION --output json \
    --query '{Objects: [Versions[], DeleteMarkers[]][][].{Key: Key, VersionId: VersionId}}' > /tmp/versions.json
  aws s3api delete-objects --bucket $bucket --region $AWS_REGION --delete file:///tmp/versions.json
  aws s3api delete-bucket --bucket $bucket --region $AWS_REGION
EOF
  fi
}

main "$@"
