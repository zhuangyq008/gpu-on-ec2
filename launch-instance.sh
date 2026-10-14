#!/usr/bin/env bash
# 单独创建 / 替换 GPU 实例 (网络栈与推理栈需已存在)
#   - 换机型、换 AMI、换模型 (修改 config.env 中 MODEL_ID) 时使用
#   - --replace: 新实例 healthy 后，自动下线并终止旧实例
#   - --retire-others <instance-id>: 该实例 healthy 时，下线并终止其它 vLLM 实例
#     (用于 --replace 等待过程中断，例如 CloudShell 会话超时)
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/gpu.sh"
source "$ROOT_DIR/lib/ami.sh"
source "$ROOT_DIR/lib/instance.sh"

usage() {
  cat <<'EOF'
用法: ./launch-instance.sh [--replace] [-y|--yes]
       ./launch-instance.sh --retire-others <instance-id>
  --replace   新实例健康后下线并终止旧实例 (零停机替换)
  --retire-others <id>  指定实例 healthy 时，下线并终止其余实例
  -y, --yes   非交互模式，使用 config.env 默认值
EOF
}

main() {
  local replace=0 keep="" rest=()
  while (( $# > 0 )); do
    case "$1" in
      --replace) replace=1 ;;
      --retire-others) keep="${2:-}"; shift ;;
      *) rest+=("$1") ;;
    esac
    shift
  done
  parse_common_flags "${rest[@]+"${rest[@]}"}"
  load_config
  check_prereqs
  load_stack_outputs

  if [[ -n "$keep" ]]; then
    [[ "$keep" =~ ^i-[0-9a-f]{8,17}$ ]] || die "实例 ID 无效: '$keep'"
    [[ "$(target_health "$keep")" == "healthy" ]] || die "$keep 不是 healthy 状态，不下线其它实例"
    local others=() i
    for i in $(existing_instances); do [[ "$i" != "$keep" ]] && others+=("$i"); done
    (( ${#others[@]} > 0 )) || { log "没有其它实例"; exit 0; }
    confirm "下线并终止 ${others[*]}?" || exit 0
    retire_instances "${others[@]}"
    exit 0
  fi

  build_gpu_catalog "$INSTANCE_FAMILIES"
  SHOW_CAPACITY_SCORE=1 select_instance_type
  check_gpu_memory_fit "$INSTANCE_TYPE"
  select_ami

  local old=()
  read -ra old <<<"$(existing_instances)"
  if (( ${#old[@]} > 0 )); then
    if (( replace )); then log "将在新实例就绪后替换: ${old[*]}"
    else warn "已存在实例 ${old[*]}，本次将额外新增一台 (NLB 会在多台之间负载均衡)"; fi
  fi
  confirm "确认以 $INSTANCE_TYPE / $AMI_ID 创建实例 (模型 $MODEL_ID)?" || exit 0

  launch_with_fallback
  register_target "$NEW_INSTANCE_ID"
  print_endpoint_info
  if (( replace )) && is_cloudshell; then
    WAIT_HEALTHY=1   # --replace 需要等待新实例就绪; 若 CloudShell 断开，用 --retire-others 收尾
  fi
  if wait_healthy "$NEW_INSTANCE_ID" 60; then
    if (( replace )); then retire_instances "${old[@]+"${old[@]}"}"; fi
  elif (( replace )); then
    warn "新实例未就绪，保留旧实例 ${old[*]}"
    warn "新实例 healthy 后执行: ./launch-instance.sh --retire-others $NEW_INSTANCE_ID"
  fi
  return 0
}

main "$@"
