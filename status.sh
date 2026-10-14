#!/usr/bin/env bash
# 查看部署状态; --test 发起一次推理请求做冒烟测试
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/instance.sh"

usage() { echo "用法: ./status.sh [--test]"; }

smoke_test() {
  local key base
  base="http://$NLB_DNS:$NLB_PORT"
  key="$(aws secretsmanager get-secret-value --secret-id "$API_KEY_SECRET_ARN" --query SecretString --output text)"
  log "GET $base/v1/models"
  curl -fsS --max-time 20 "$base/v1/models" -H "Authorization: Bearer $key" | jq -r '.data[].id' \
    || die "/v1/models 调用失败"
  log "POST $base/v1/chat/completions"
  local body
  body="$(jq -n --arg m "$MODEL_ID" \
    '{model:$m, messages:[{role:"user",content:"用一句话介绍马来西亚。"}], max_tokens:512,
      chat_template_kwargs:{enable_thinking:false}}')"
  curl -fsS --max-time 300 "$base/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "$body" \
    | jq '{content: .choices[0].message.content, usage}' \
    || die "chat/completions 调用失败"
  log "未携带 API Key 的请求应返回 401:"
  curl -s -o /dev/null -w '  HTTP %{http_code}\n' --max-time 20 "$base/v1/models" >&2
}

main() {
  local test=0
  case "${1:-}" in
    --test) test=1 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) die "未知参数: $1" ;;
  esac
  load_config
  require_cmds aws jq curl
  load_stack_outputs

  log "实例:"
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$INSTANCE_ROLE_TAG" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.AvailabilityZone,State.Name,PrivateIpAddress,KeyName,LaunchTime]' \
    --output table >&2
  log "Target Group 健康状态:"
  aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table >&2
  print_endpoint_info
  if stack_ready "$BASTION_STACK"; then
    local ip iid
    ip="$(stack_output "$BASTION_STACK" BastionPublicIp)"
    iid="$(stack_output "$BASTION_STACK" BastionInstanceId)"
    printf '\n 跳板机   : %s (%s)  ssh -i %s/%s.pem ec2-user@%s  |  aws ssm start-session --target %s\n' \
      "$iid" "$ip" "$SSH_KEY_DIR" "$OPS_KEY_NAME" "$ip" "$iid" >&2
  fi
  (( test )) && smoke_test
  return 0
}

main "$@"
