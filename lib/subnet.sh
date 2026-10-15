#!/usr/bin/env bash
# shellcheck disable=SC2034  # NODE_* 变量供 gpu-node.sh 使用
# 子网发现与选择: 按路由表判断公有/私有，本项目 VPC 优先，默认私有子网

SUBNETS_JSON=""

# build_subnet_catalog -> SUBNETS_JSON
# [{id,name,az,cidr,vpc,vpcName,vpcCidr,public,freeIps,project}] 排序: 本项目 VPC > 私有 > AZ
build_subnet_catalog() {
  local project_vpc="" subnets rts vpcs
  stack_ready "$NETWORK_STACK" && project_vpc="$(stack_output "$NETWORK_STACK" VpcId)"
  subnets="$(aws ec2 describe-subnets --output json \
    --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,cidr:CidrBlock,vpc:VpcId,free:AvailableIpAddressCount,tags:Tags}')" \
    || die "查询子网失败"
  rts="$(aws ec2 describe-route-tables --output json \
    --query 'RouteTables[].{vpc:VpcId,assoc:Associations,routes:Routes}')" || die "查询路由表失败"
  vpcs="$(aws ec2 describe-vpcs --output json --query 'Vpcs[].{id:VpcId,cidr:CidrBlock,tags:Tags}')" \
    || die "查询 VPC 失败"
  SUBNETS_JSON="$(jq -n --argjson s "$subnets" --argjson r "$rts" --argjson v "$vpcs" --arg pv "$project_vpc" '
    def tagname: ((.tags // []) | map(select(.Key == "Name")) | .[0].Value // "-");
    def is_public: any(.routes[]?; .DestinationCidrBlock == "0.0.0.0/0" and ((.GatewayId // "") | startswith("igw-")));
    ($r | map(select(any(.assoc[]?; .Main == true))) | map({key: .vpc, value: is_public}) | from_entries) as $main
    | ($r | [ .[] as $t | $t.assoc[]? | select(.SubnetId != null) | {key: .SubnetId, value: ($t | is_public)} ]
          | from_entries) as $explicit
    | ($v | map({key: .id, value: {name: tagname, cidr: .cidr}}) | from_entries) as $vinfo
    | [ $s[] | {
          id, az, cidr, vpc, freeIps: .free, name: tagname,
          vpcName: ($vinfo[.vpc].name // "-"), vpcCidr: ($vinfo[.vpc].cidr // ""),
          public: (if $explicit[.id] != null then $explicit[.id] else ($main[.vpc] // false) end),
          project: (.vpc == $pv)
        } ]
    | sort_by((if .project then 0 else 1 end), .vpc, (if .public then 1 else 0 end), .az, .id)')"
}

# 当前机型在某 AZ 是否有供应
type_offered_in_az() {
  jq -e --arg t "$1" --arg a "$2" 'any(.[]; .type == $t and (.azs | index($a)))' <<<"$GPU_CATALOG_JSON" >/dev/null
}

# select_subnet <机型> -> NODE_SUBNET_ID NODE_VPC_ID NODE_VPC_CIDR NODE_AZ NODE_SUBNET_PUBLIC
select_subnet() {
  local itype="$1" n i=0 row def=0 offered idx mark
  n="$(jq length <<<"$SUBNETS_JSON")"
  (( n > 0 )) || die "$AWS_REGION 中没有可用子网"
  printf '\n%-4s %-26s %-24s %-17s %-17s %-6s %-6s %s\n' \
    "#" "Subnet" "Name" "AZ" "CIDR" "类型" "$itype" "VPC" >&2
  printf '%s\n' "---------------------------------------------------------------------------------------------------------------------" >&2
  while IFS= read -r row; do
    i=$((i + 1))
    offered="✗"; type_offered_in_az "$itype" "$(jq -r .az <<<"$row")" && offered="✓"
    # 默认: 第一个私有且机型可用的子网 (本项目 VPC 排在最前)
    if (( def == 0 )) && [[ "$(jq -r .public <<<"$row")" == "false" && "$offered" == "✓" ]]; then def=$i; fi
    mark=""; [[ "$(jq -r .project <<<"$row")" == "true" ]] && mark=" (本项目)"
    printf '%-4s %-26s %-24.24s %-17s %-17s %-6s %-6s %s\n' "$i" "$(jq -r .id <<<"$row")" \
      "$(jq -r .name <<<"$row")" "$(jq -r .az <<<"$row")" "$(jq -r .cidr <<<"$row")" \
      "$([[ "$(jq -r .public <<<"$row")" == "true" ]] && echo 公有 || echo 私有)" "$offered" \
      "$(jq -r '.vpc + " " + .vpcName' <<<"$row")$mark" >&2
  done < <(jq -c '.[]' <<<"$SUBNETS_JSON")
  printf '\n类型: 路由表中 0.0.0.0/0 指向 Internet Gateway 为公有，否则为私有。GPU 机器建议放在私有子网。\n\n' >&2
  (( def > 0 )) || def=1

  if [[ -n "${NODE_SUBNET_ID:-}" ]]; then
    idx="$(jq --arg s "$NODE_SUBNET_ID" 'map(.id) | index($s) // empty | . + 1' <<<"$SUBNETS_JSON")"
    [[ -n "$idx" ]] || die "NODE_SUBNET_ID=$NODE_SUBNET_ID 不存在"
  else
    idx="$(choose_index "请选择子网编号" "$def" "$n")"
  fi
  row="$(jq -c --argjson i "$((idx - 1))" '.[$i]' <<<"$SUBNETS_JSON")"
  NODE_SUBNET_ID="$(jq -r .id <<<"$row")"; NODE_VPC_ID="$(jq -r .vpc <<<"$row")"
  NODE_VPC_CIDR="$(jq -r .vpcCidr <<<"$row")"; NODE_AZ="$(jq -r .az <<<"$row")"
  NODE_SUBNET_PUBLIC="$(jq -r .public <<<"$row")"
  ok "已选择子网: $NODE_SUBNET_ID ($NODE_AZ, $([[ "$NODE_SUBNET_PUBLIC" == "true" ]] && echo 公有 || echo 私有), VPC $NODE_VPC_ID)"
  if ! type_offered_in_az "$itype" "$NODE_AZ"; then
    warn "$itype 在 $NODE_AZ 没有供应，创建一定会失败"
    confirm "仍然继续?" || exit 1
  fi
  if [[ "$NODE_SUBNET_PUBLIC" == "true" ]]; then
    warn "选择的是公有子网: GPU 机器会分配公网 IP (安全组仍只放行 VPC 内与跳板机)。建议使用私有子网"
    confirm "确认使用公有子网?" || exit 1
  fi
  return 0
}

# 同 VPC 内同类型 (公有/私有) 的子网，逗号分隔，供跨 AZ 容量回退; 可限定 AZ 列表 (空格分隔)
sibling_subnets() {
  local azs="${1:-}"
  jq -r --arg v "$NODE_VPC_ID" --argjson p "$NODE_SUBNET_PUBLIC" --arg azs "$azs" '
    [ .[] | select(.vpc == $v and .public == $p)
          | select($azs == "" or (.az as $a | $azs | split(" ") | index($a))) | .id ] | join(",")' \
    <<<"$SUBNETS_JSON"
}

# NLB 用的公有子网: 所选 VPC 内每个 AZ 取一个，输出 "subnet,subnet" 与 AZ 列表
nlb_public_subnets() {
  jq -r --arg v "$NODE_VPC_ID" '
    [ .[] | select(.vpc == $v and .public) ] | group_by(.az) | map(.[0])
    | (map(.id) | join(",")) + " " + (map(.az) | join(" "))' <<<"$SUBNETS_JSON"
}
