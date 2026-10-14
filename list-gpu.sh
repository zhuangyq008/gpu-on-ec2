#!/usr/bin/env bash
# 列出 Region 内 GPU 机型、可用 AZ、配额与容量参考分
#   ./list-gpu.sh                       # 默认 INSTANCE_FAMILIES (g6)
#   ./list-gpu.sh g6 g6e g7e            # 指定家族
#   TARGET_REGION=ap-southeast-1 ./list-gpu.sh g6
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/gpu.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
  load_config
  require_cmds aws jq
  local families="${*:-$INSTANCE_FAMILIES}"
  log "Region $AWS_REGION，GPU 家族: $families (容量参考分查询较慢，请稍候)"
  build_gpu_catalog "$families"
  if [[ "$(gpu_catalog_count)" == "0" ]]; then
    warn "$AWS_REGION 内没有 [$families] 家族的机型"
    exit 0
  fi
  print_gpu_table 1
}

main "$@"
