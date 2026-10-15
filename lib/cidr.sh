#!/usr/bin/env bash
# 来源 CIDR 白名单: 校验、去重、公网放行确认、CloudFormation 槽位参数

cidr_re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]|[12][0-9]|3[0-2])$'

valid_cidr() {
  [[ "$1" =~ $cidr_re ]] || return 1
  local i
  for i in 1 2 3 4; do (( BASH_REMATCH[i] <= 255 )) || return 1; done
}

# 交互时的默认来源: 非 CloudShell 环境取本机公网 IP/32 (CloudShell 出口 IP 不是用户本机 IP)
default_client_cidr() {
  if is_cloudshell; then
    warn "在 CloudShell 中无法自动获取你本机的公网 IP，请在本机浏览器打开 https://checkip.amazonaws.com 查看"
    return 0
  fi
  local ip
  ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$ip" ]] && printf '%s/32' "$ip"
}

# normalize_cidrs <逗号分隔列表> <最大个数> <用途说明> -> stdout 去重后的逗号分隔列表
# 前缀短于 /8 视为公网: 交互模式需确认，--yes 模式需 ALLOW_PUBLIC_CIDR=1
normalize_cidrs() {
  local list="${1// /}" max="$2" what="$3" c uniq=() items=()
  [[ -n "$list" ]] || die "$what 的来源 CIDR 不能为空"
  IFS=',' read -ra items <<<"$list"
  for c in "${items[@]}"; do
    [[ -z "$c" ]] && continue
    valid_cidr "$c" || die "CIDR 格式错误: '$c'"
    [[ " ${uniq[*]} " == *" $c "* ]] && continue
    uniq+=("$c")
    if (( ${c##*/} < 8 )); then
      warn "$c 会把 $what 暴露给整个互联网"
      if [[ "$ASSUME_YES" == "1" ]]; then
        [[ "${ALLOW_PUBLIC_CIDR:-0}" == "1" ]] || die "非交互模式下使用 $c 需设置 ALLOW_PUBLIC_CIDR=1"
      else
        confirm "确认使用 $c?" || exit 1
      fi
    elif (( ${c##*/} < 16 )); then
      warn "$c 范围较大 (超过 /16)，请确认是否必要"
      if [[ "$ASSUME_YES" == "1" ]]; then
        [[ "${ALLOW_PUBLIC_CIDR:-0}" == "1" ]] || die "非交互模式下使用 $c 需设置 ALLOW_PUBLIC_CIDR=1"
      else
        confirm "确认使用 $c?" || exit 1
      fi
    fi
  done
  (( ${#uniq[@]} > 0 )) || die "$what 的来源 CIDR 不能为空"
  (( ${#uniq[@]} <= max )) || die "$what 的来源 CIDR 最多 $max 个"
  (IFS=,; printf '%s' "${uniq[*]}")
}

# cidr_slot_params <参数名前缀> <槽位数> <逗号分隔列表> -> 每行一个 Key=Value (未用槽位为空串)
cidr_slot_params() {
  local prefix="$1" slots="$2" arr=() i
  IFS=',' read -ra arr <<<"$3"
  for i in $(seq 1 "$slots"); do printf '%s%d=%s\n' "$prefix" "$i" "${arr[i-1]:-}"; done
}

# deployed_cidrs <stack> <参数名前缀> -> 已部署栈中的 CIDR 列表 (逗号分隔)，栈不存在时为空
deployed_cidrs() {
  stack_ready "$1" || return 0
  aws cloudformation describe-stacks --stack-name "$1" --output json \
    --query "Stacks[0].Parameters[?starts_with(ParameterKey,'$2')]" \
  | jq -r --arg p "$2" 'sort_by(.ParameterKey | ltrimstr($p) | tonumber)
           | map(.ParameterValue | select(. != "")) | join(",")'
}

# resolve_cidr_list <当前值> <stack> <参数名前缀> <最大个数> <用途说明> -> stdout 最终列表
# 优先级: 配置值 > 已部署栈中的值 > 交互输入 (默认本机 IP)
resolve_cidr_list() {
  local value="$1" stack="$2" prefix="$3" max="$4" what="$5" def
  if [[ -z "$value" ]]; then
    def="$(deployed_cidrs "$stack" "$prefix")"
    if [[ -n "$def" ]]; then
      log "沿用已部署的 $what 来源 CIDR: $def"
    else
      def="$(default_client_cidr)"
    fi
    [[ "$ASSUME_YES" == "1" && -z "$def" ]] && die "非交互模式下必须配置 $what 的来源 CIDR"
    value="$(prompt_default "允许访问 $what 的来源 CIDR (逗号分隔，如 203.0.113.10/32)" "$def")"
  fi
  normalize_cidrs "$value" "$max" "$what"
}
