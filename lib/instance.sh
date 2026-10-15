#!/usr/bin/env bash
# shellcheck disable=SC2153  # OPS_KEY_NAME 等变量由 load_config 设置
# GPU 实例: user-data 渲染、跨 AZ/机型容量回退创建、注册 NLB、健康等待

INSTANCE_ROLE_TAG="vllm"

# 启动参数 (LAUNCH_*): 默认用于 vLLM 实例，gpu-node.sh 会覆盖为裸 GPU 机器的值
#   LAUNCH_SUBNET_IDS      候选子网 (逗号分隔)，默认网络栈的私有子网
#   LAUNCH_PREFERRED_SUBNET 优先尝试的子网 (用户选择的子网)
#   LAUNCH_SG_IDS / LAUNCH_PROFILE / LAUNCH_ROLE_TAG / LAUNCH_NAME / LAUNCH_EXTRA_TAGS
#   LAUNCH_HOP_LIMIT / LAUNCH_ROOT_GB / LAUNCH_PUBLIC_IP / LAUNCH_USER_DATA_FN
# 读取两个栈的输出到全局变量
load_stack_outputs() {
  stack_ready "$NETWORK_STACK" || die "网络栈 $NETWORK_STACK 未就绪 ($(stack_status "$NETWORK_STACK"))，请先运行 ./deploy.sh"
  stack_ready "$INFERENCE_STACK" || die "推理栈 $INFERENCE_STACK 未就绪 ($(stack_status "$INFERENCE_STACK"))，请先运行 ./deploy.sh"
  PRIVATE_SUBNET_IDS="$(stack_output "$NETWORK_STACK" PrivateSubnetIds)"
  TARGET_GROUP_ARN="$(stack_output "$INFERENCE_STACK" TargetGroupArn)"
  INSTANCE_SG_ID="$(stack_output "$INFERENCE_STACK" InstanceSecurityGroupId)"
  INSTANCE_PROFILE_NAME="$(stack_output "$INFERENCE_STACK" InstanceProfileName)"
  API_KEY_SECRET_ARN="$(stack_output "$INFERENCE_STACK" ApiKeySecretArn)"
  MODEL_BUCKET_NAME="$(stack_output "$INFERENCE_STACK" ModelBucketName)"
  MODEL_S3_PREFIX_OUT="$(stack_output "$INFERENCE_STACK" ModelS3Prefix)"
  LOG_GROUP_NAME="$(stack_output "$INFERENCE_STACK" LogGroupName)"
  NLB_DNS="$(stack_output "$INFERENCE_STACK" NlbDnsName)"
  NLB_PORT="$(stack_output "$INFERENCE_STACK" ListenerPort)"
}

# 写入实例 /etc/llm/llm.env 的内容 (使用 %q 安全转义)
render_env_file() {
  local k
  for k in AWS_REGION MODEL_ID MODEL_REVISION VLLM_IMAGE VLLM_MAX_MODEL_LEN VLLM_GPU_MEMORY_UTILIZATION \
           VLLM_TENSOR_PARALLEL_SIZE VLLM_EXTRA_ARGS HF_TOKEN_SECRET_ARN; do
    printf '%s=%q\n' "$k" "${!k}"
  done
  printf 'MODEL_BUCKET=%q\nMODEL_S3_PREFIX=%q\nAPI_KEY_SECRET_ARN=%q\nLOG_GROUP=%q\n' \
    "$MODEL_BUCKET_NAME" "$MODEL_S3_PREFIX_OUT" "$API_KEY_SECRET_ARN" "$LOG_GROUP_NAME"
}

# 输出 gzip 后的 user-data 到文件 $1
render_user_data() {
  local out="$1"
  {
    printf '#!/bin/bash\nset -euo pipefail\nexec > >(tee -a /var/log/llm-userdata.log) 2>&1\n'
    printf 'install -d -m 755 /opt/llm\ninstall -d -m 700 /etc/llm\n'
    printf "cat >/etc/llm/llm.env <<'__ENV__'\n%s\n__ENV__\nchmod 600 /etc/llm/llm.env\n" "$(render_env_file)"
    printf "cat >/opt/llm/prepare.sh <<'__PREPARE__'\n%s\n__PREPARE__\n" "$(cat "$ROOT_DIR/instance/prepare.sh")"
    printf "cat >/opt/llm/run-vllm.sh <<'__RUN__'\n%s\n__RUN__\n" "$(cat "$ROOT_DIR/instance/run-vllm.sh")"
    printf 'chmod 755 /opt/llm/prepare.sh /opt/llm/run-vllm.sh\n'
    cat "$ROOT_DIR/instance/setup.sh"
  } | gzip -9 >"$out"
  local size
  size="$(wc -c <"$out")"
  (( size < 16384 )) || die "user-data 超过 16KB 限制 ($size bytes)"
}

# subnet -> AZ 映射，输出 "subnet-xxx az" 行，按容量参考分降序
ordered_subnets_for_type() {
  local itype="$1" offered scores
  offered="$(jq -r --arg t "$itype" '.[] | select(.type == $t) | .azs[]' <<<"$GPU_CATALOG_JSON")"
  scores="$(get_capacity_scores "$itype")"
  [[ -n "$scores" ]] || scores='{}' 
  local subnet_ids preferred="${LAUNCH_PREFERRED_SUBNET:-}"
  IFS=',' read -ra subnet_ids <<<"${LAUNCH_SUBNET_IDS:-$PRIVATE_SUBNET_IDS}"
  aws ec2 describe-subnets --subnet-ids "${subnet_ids[@]}" \
    --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text \
  | while read -r sid az; do
      grep -qx "$az" <<<"$offered" || continue
      local score
      score="$(jq -r --arg a "$az" '.[$a] // 0' <<<"$scores" 2>/dev/null || echo 0)"
      [[ "$sid" == "$preferred" ]] && score=100   # 用户选择的子网最先尝试
      printf '%s %s %s\n' "$score" "$sid" "$az"
    done | sort -rn | awk '{print $2, $3}'
}

existing_instances() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$INSTANCE_ROLE_TAG" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# try_run_instance <type> <subnet> <userdata-file> -> stdout instance-id; 返回 2 表示容量不足
try_run_instance() {
  local itype="$1" subnet="$2" udfile="$3" root_dev out rc=0
  root_dev="$(aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].RootDeviceName' --output text)"
  local name="${LAUNCH_NAME:-$PROJECT_NAME-vllm}" extra_tags="${LAUNCH_EXTRA_TAGS-{Key=Model,Value=$MODEL_ID\}}"
  local sgs=()
  read -ra sgs <<<"${LAUNCH_SG_IDS:-$INSTANCE_SG_ID}"
  local args=(
    --image-id "$AMI_ID" --instance-type "$itype"
    --iam-instance-profile "Name=${LAUNCH_PROFILE:-$INSTANCE_PROFILE_NAME}"
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=${LAUNCH_HOP_LIMIT:-1},HttpEndpoint=enabled"
    --block-device-mappings "DeviceName=$root_dev,Ebs={VolumeSize=${LAUNCH_ROOT_GB:-$ROOT_VOLUME_GB},VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}"
    --user-data "fileb://$udfile"
    --tag-specifications
      "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Project,Value=$PROJECT_NAME},{Key=Role,Value=${LAUNCH_ROLE_TAG:-$INSTANCE_ROLE_TAG}}${extra_tags:+,$extra_tags}]"
      "ResourceType=volume,Tags=[{Key=Name,Value=$name-root},{Key=Project,Value=$PROJECT_NAME}]"
    --count 1 --query 'Instances[0].InstanceId' --output text
  )
  if [[ "${LAUNCH_PUBLIC_IP:-0}" == "1" ]]; then
    args+=(--network-interfaces "DeviceIndex=0,SubnetId=$subnet,AssociatePublicIpAddress=true,Groups=$(IFS=,; echo "${sgs[*]}")")
  else
    args+=(--subnet-id "$subnet" --security-group-ids "${sgs[@]}")
  fi
  [[ -n "${GPU_KEY_NAME:-}" ]] && args+=(--key-name "$GPU_KEY_NAME")
  [[ -n "$CAPACITY_RESERVATION_ID" ]] && \
    args+=(--capacity-reservation-specification "CapacityReservationTarget={CapacityReservationId=$CAPACITY_RESERVATION_ID}")
  local attempt
  for attempt in 1 2 3 4 5 6; do
    rc=0; out="$(aws ec2 run-instances "${args[@]}" 2>&1)" || rc=$?
    # 新建的 instance profile 需要几秒到几十秒才能在 EC2 侧生效
    if (( rc != 0 )) && grep -q 'Invalid IAM Instance Profile' <<<"$out"; then
      log "  instance profile 尚未生效，${attempt}0s 后重试..."; sleep $((attempt * 10)); continue
    fi
    break
  done
  if (( rc == 0 )); then printf '%s' "$out"; return 0; fi
  if grep -qE '\((InsufficientInstanceCapacity|InsufficientCapacity|InsufficientHostCapacity|Unsupported)\)' <<<"$out"; then
    warn "  容量不足: $(grep -oE '\((InsufficientInstanceCapacity|InsufficientCapacity|InsufficientHostCapacity|Unsupported)\)' <<<"$out" | head -1)"
    return 2
  fi
  if grep -qE 'VcpuLimitExceeded|InstanceLimitExceeded' <<<"$out"; then
    die "vCPU 配额不足: $out"
  fi
  die "run-instances 失败: $out"
}

# launch_with_fallback -> 设置 NEW_INSTANCE_ID
launch_with_fallback() {
  USER_DATA_FILE="$(mktemp)"
  trap 'rm -f "$USER_DATA_FILE"' EXIT
  "${LAUNCH_USER_DATA_FN:-render_user_data}" "$USER_DATA_FILE"
  GPU_KEY_NAME="$(gpu_key_name)"
  if [[ -n "$GPU_KEY_NAME" ]]; then
    log "GPU 实例挂载 SSH key: $GPU_KEY_NAME (可经跳板机 ssh -J 登录)"
  else
    log "未找到运维 key pair $OPS_KEY_NAME，GPU 实例不挂 SSH key (可用 SSM 登录; 先运行 ./deploy-bastion.sh 可启用 SSH)"
  fi
  local udfile="$USER_DATA_FILE"

  local types=("$INSTANCE_TYPE") t round sid az rc
  for t in $FALLBACK_INSTANCE_TYPES; do [[ "$t" != "$INSTANCE_TYPE" ]] && types+=("$t"); done

  for round in $(seq 1 "$CAPACITY_RETRY_ROUNDS"); do
    log "容量尝试第 $round/$CAPACITY_RETRY_ROUNDS 轮 (机型: ${types[*]})"
    for t in "${types[@]}"; do
      local candidates
      candidates="$(ordered_subnets_for_type "$t")"
      [[ -n "$candidates" ]] || { warn "  $t 在 VPC 的 AZ 中都不提供，跳过"; continue; }
      while read -r sid az; do
        log "  尝试 $t @ $az ($sid)"
        rc=0; NEW_INSTANCE_ID="$(try_run_instance "$t" "$sid" "$udfile")" || rc=$?
        if (( rc == 0 )); then
          ok "已创建实例 $NEW_INSTANCE_ID ($t @ $az)"
          return 0
        fi
        (( rc == 2 )) || exit 1   # 非容量类错误: try_run_instance 已打印原因
      done <<<"$candidates"
    done
    if (( round < CAPACITY_RETRY_ROUNDS )); then
      log "所有 AZ 暂无容量，${CAPACITY_RETRY_INTERVAL_SEC}s 后重试..."
      sleep "$CAPACITY_RETRY_INTERVAL_SEC"
    fi
  done
  die "所有 AZ / 机型都没有可用容量。建议: 1) 稍后重试 2) 配置 FALLBACK_INSTANCE_TYPES 3) 购买 ODCR / Capacity Block 后设置 CAPACITY_RESERVATION_ID"
}

register_target() {
  local iid="$1"
  log "等待实例 $iid 进入 running ..."
  aws ec2 wait instance-running --instance-ids "$iid"
  aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "Id=$iid,Port=8000"
  ok "已注册到 Target Group"
}

target_health() {
  aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" \
    --targets "Id=$1,Port=8000" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null
}

# wait_healthy <instance-id> [timeout_min]
wait_healthy() {
  local iid="$1" timeout_min="${2:-60}" start state
  if is_cloudshell && [[ "${WAIT_HEALTHY:-0}" != "1" ]]; then
    log "检测到 AWS CloudShell: 不在此等待 vLLM 就绪 (首次约 15-40 分钟，CloudShell 无输入会断开)"
    log "部署已完成，实例会自行完成初始化。稍后运行 ./status.sh 查看，healthy 后运行 ./status.sh --test 测试"
    return 1
  fi
  start="$(date +%s)"
  log "等待 vLLM 健康检查通过 (首次需要拉镜像 + 下载权重，可能 15-40 分钟; Ctrl+C 可退出，不影响部署)"
  log "实例日志: aws ssm start-session --target $iid  然后  sudo journalctl -u vllm -f"
  while true; do
    state="$(target_health "$iid")"
    if [[ "$state" == "healthy" ]]; then ok "Target $iid healthy"; return 0; fi
    if (( $(date +%s) - start > timeout_min * 60 )); then
      warn "超过 ${timeout_min} 分钟仍未 healthy (当前: $state)，请用 ./status.sh 继续观察"
      return 1
    fi
    printf '  [%s] target=%s  已等待 %d 分钟\n' "$(date +%H:%M:%S)" "$state" $(( ($(date +%s) - start) / 60 )) >&2
    sleep 30
  done
}

retire_instances() {
  local ids=("$@") iid
  (( ${#ids[@]} > 0 )) || return 0
  local targets=()
  for iid in "${ids[@]}"; do targets+=("Id=$iid,Port=8000"); done
  aws elbv2 deregister-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "${targets[@]}" || true
  # 等待 NLB 连接排空 (deregistration_delay) 后再终止，避免中断进行中的请求
  log "等待旧实例从 NLB 摘除并排空连接 (约 1-2 分钟)..."
  aws elbv2 wait target-deregistered --target-group-arn "$TARGET_GROUP_ARN" --targets "${targets[@]}" \
    || warn "等待摘除超时，继续终止"
  aws ec2 terminate-instances --instance-ids "${ids[@]}" >/dev/null
  ok "已下线并终止旧实例: ${ids[*]}"
}

print_endpoint_info() {
  cat >&2 <<EOF

================================ 推理服务信息 ================================
 Endpoint : http://$NLB_DNS:$NLB_PORT/v1
 Model    : $MODEL_ID
 API Key  : aws secretsmanager get-secret-value --region $AWS_REGION \\
              --secret-id $API_KEY_SECRET_ARN --query SecretString --output text
 权重位置 : s3://$MODEL_BUCKET_NAME/$MODEL_S3_PREFIX_OUT/$MODEL_ID/$MODEL_REVISION/
 日志     : CloudWatch Logs  $LOG_GROUP_NAME

 测试:
   export API_KEY=\$(aws secretsmanager get-secret-value --region $AWS_REGION --secret-id $API_KEY_SECRET_ARN --query SecretString --output text)
   curl http://$NLB_DNS:$NLB_PORT/v1/chat/completions -H "Authorization: Bearer \$API_KEY" \\
     -H 'Content-Type: application/json' \\
     -d '{"model":"$MODEL_ID","messages":[{"role":"user","content":"你好"}],"max_tokens":256}'
==============================================================================
EOF
}
