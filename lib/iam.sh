#!/usr/bin/env bash
# 共用 GPU Instance Role (推理栈 InstanceRole / InstanceProfile) 的 S3 bucket 列表管理
#   - 模型 bucket 始终可读写
#   - GPU_S3_BUCKETS: 额外可读写的 bucket，deploy.sh 按配置精确设置; gpu-node.sh 只增不减

_partition() { aws sts get-caller-identity --query Arn --output text | cut -d: -f2; }

# 已部署的额外 bucket 名 (空格分隔)
deployed_gpu_buckets() {
  stack_ready "$INFERENCE_STACK" || return 0
  aws cloudformation describe-stacks --stack-name "$INFERENCE_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='GpuS3BucketArns'].ParameterValue | [0]" --output text \
  | tr ',' '\n' | sed -n 's#^arn:[a-z-]*:s3:::##p' | grep -E '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' | xargs
}

# gpu_bucket_params "<bucket ...>" -> 两行 GpuS3BucketArns=... / GpuS3ObjectArns=... (模型 bucket 不重复列出)
gpu_bucket_params() {
  local partition b arns=() objs=() seen=" "
  partition="$(_partition)"
  for b in $1; do
    [[ "$b" == "${MODEL_BUCKET_NAME:-}" || "$seen" == *" $b "* ]] && continue
    seen+="$b "
    arns+=("arn:$partition:s3:::$b"); objs+=("arn:$partition:s3:::$b/*")
  done
  printf 'GpuS3BucketArns=%s\nGpuS3ObjectArns=%s\n' "$(IFS=,; echo "${arns[*]}")" "$(IFS=,; echo "${objs[*]}")"
}

# ensure_gpu_buckets "<bucket ...>": 把缺少的 bucket 合并进共用 Role (只增不减)
ensure_gpu_buckets() {
  local want="$1" have b missing=()
  have="$(deployed_gpu_buckets)"
  for b in $want; do
    [[ "$b" == "$MODEL_BUCKET_NAME" || " $have " == *" $b "* ]] || missing+=("$b")
  done
  (( ${#missing[@]} > 0 )) || return 0
  log "共用 GPU Instance Role 新增 S3 bucket: ${missing[*]} (已有: ${have:-无})"
  local params=()
  mapfile -t params < <(gpu_bucket_params "$have ${missing[*]}")
  # 只覆盖 bucket 参数，其余参数沿用已部署的值
  deploy_stack "$INFERENCE_STACK" "$ROOT_DIR/cfn/inference.yaml" "${params[@]}"
}

# 推理栈仍是旧模板 (共用 Role 尚无 ECR / 额外 bucket 权限) 时，用当前模板升级 (参数沿用，不替换 Role)
upgrade_shared_role_if_needed() {
  local has
  has="$(aws cloudformation describe-stacks --stack-name "$INFERENCE_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='GpuS3BucketArns'] | length(@)" --output text)"
  [[ "$has" == "0" ]] || return 0
  warn "将升级共用 GPU Instance Role (Role / Profile 不替换): 新增 ECR 只读、模型 bucket 整体读写删;"
  warn "  该 Role 被所有 GPU 机器共用 (含已运行的 vLLM 实例)，它们会同时获得这些权限"
  confirm "确认升级共用 Role?" || exit 0
  deploy_stack "$INFERENCE_STACK" "$ROOT_DIR/cfn/inference.yaml"
}

# 共用 Role 当前可访问的全部 bucket (含模型 bucket)
gpu_role_buckets() {
  printf '%s' "$MODEL_BUCKET_NAME"
  local extra
  extra="$(deployed_gpu_buckets)"
  [[ -n "$extra" ]] && printf ' %s' "$extra"
  printf '\n'
}
