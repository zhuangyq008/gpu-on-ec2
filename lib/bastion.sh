#!/usr/bin/env bash
# shellcheck disable=SC2034  # BASTION_* 变量供 deploy-bastion.sh 使用
# 跳板机机型选择: x86_64 / arm64 推荐机型 + 实时按需价格 + 自定义机型

# 推荐机型: "机型|适用场景"，按架构分组
BASTION_RECOMMENDED=(
  "t3.small|默认推荐: 日常 SSH/SSM 跳转、aws cli、少量文件传输"
  "t3.medium|需要较多内存: 运行 tmux 多会话、python 脚本、较大文件 s3 sync"
  "m7i-flex.large|持续负载 (非突发): 长时间数据处理 / 压测客户端"
  "t4g.small|ARM 版默认推荐: 同等规格比 t3.small 便宜约 20%"
  "t4g.medium|ARM: 需要较多内存的运维场景"
  "m7g.large|ARM 持续负载 (非突发)"
)

# 机型信息 -> "arch vcpu memMiB"，机型不存在时返回非 0
instance_type_info() {
  aws ec2 describe-instance-types --instance-types "$1" \
    --query 'InstanceTypes[0].[ProcessorInfo.SupportedArchitectures[0],VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' \
    --output text 2>/dev/null
}

type_offered_in() {  # type_offered_in <type> <az>
  aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$1" "Name=location,Values=$2" \
    --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null | grep -qx "$1"
}

# Linux 按需价格 (USD/小时)，取不到时为空 (需要 pricing:GetProducts 权限)
on_demand_price() {
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 --max-items 1 --filters \
    "Type=TERM_MATCH,Field=instanceType,Value=$1" "Type=TERM_MATCH,Field=regionCode,Value=$AWS_REGION" \
    "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --query 'PriceList[0]' --output text 2>/dev/null \
  | jq -r '[.terms.OnDemand[].priceDimensions[].pricePerUnit.USD][0] | tonumber | . * 10000 | round / 10000' 2>/dev/null \
  || true
}

# 已部署跳板机的机型 (栈参数)，未部署为空
deployed_bastion_type() {
  stack_ready "$BASTION_STACK" || return 0
  aws cloudformation describe-stacks --stack-name "$BASTION_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='InstanceType'].ParameterValue | [0]" --output text
}

offered_in_any() {  # offered_in_any <type> <az...>
  local t="$1" az; shift
  for az in "$@"; do type_offered_in "$t" "$az" && return 0; done
  return 1
}

# select_bastion_type <az...> -> BASTION_INSTANCE_TYPE / BASTION_ARCH
# 优先级: BASTION_INSTANCE_TYPE 配置 > 已部署机型 > 交互选择 (默认 t3.small)
select_bastion_type() {
  local azs=("$@") deployed def_type entry t note info arch vcpu mem price i=0 def_idx=1 idx
  deployed="$(deployed_bastion_type)"
  def_type="${BASTION_INSTANCE_TYPE:-${deployed:-t3.small}}"

  if [[ -n "$BASTION_INSTANCE_TYPE" || "$ASSUME_YES" == "1" ]]; then
    BASTION_INSTANCE_TYPE="$def_type"
  else
    printf '\n跳板机机型 (%s，价格为 Linux 按需参考价):\n' "${azs[*]}" >&2
    printf '%-4s %-16s %-8s %-5s %-7s %-11s %s\n' "#" "机型" "架构" "vCPU" "内存" "USD/小时" "适用场景" >&2
    printf '%s\n' "------------------------------------------------------------------------------------------------" >&2
    local types=()
    for entry in "${BASTION_RECOMMENDED[@]}"; do
      t="${entry%%|*}"; note="${entry#*|}"
      offered_in_any "$t" "${azs[@]}" || continue
      read -r arch vcpu mem <<<"$(instance_type_info "$t")"
      price="$(on_demand_price "$t")"
      i=$((i + 1)); types+=("$t")
      [[ "$t" == "$def_type" ]] && def_idx=$i
      printf '%-4s %-16s %-8s %-5s %-7s %-11s %s\n' "$i" "$t" "$arch" "$vcpu" "$((mem / 1024))GiB" \
        "${price:+\$$price}" "$note" >&2
    done
    i=$((i + 1))
    printf '%-4s %s\n' "$i" "其他机型 (手动输入，如 c7i.large / m8g.large)" >&2
    printf '\n说明: t 系列为突发性能实例 (CPU 积分，默认 unlimited 模式，长期高负载会产生额外费用);\n' >&2
    printf '      arm64 (Graviton) 同规格约便宜 20%%，跳板机上的 aws cli / ssh / python 均原生支持 arm64。\n' >&2
    [[ -n "$deployed" ]] && printf '      当前已部署: %s\n' "$deployed" >&2
    printf '\n' >&2
    if [[ -n "$deployed" && " ${types[*]} " != *" $deployed "* ]]; then def_idx=$i; fi
    idx="$(choose_index "请选择跳板机机型编号" "$def_idx" "$i")"
    if (( idx == i )); then
      BASTION_INSTANCE_TYPE="$(prompt_default "输入机型" "${deployed:-t3.small}")"
    else
      BASTION_INSTANCE_TYPE="${types[idx-1]}"
    fi
  fi

  [[ "$BASTION_INSTANCE_TYPE" =~ ^[a-z0-9-]+\.[a-z0-9-]+$ ]] || die "机型名称无效: '$BASTION_INSTANCE_TYPE'"
  info="$(instance_type_info "$BASTION_INSTANCE_TYPE")" || die "机型 $BASTION_INSTANCE_TYPE 不存在"
  read -r BASTION_ARCH vcpu mem <<<"$info"
  [[ "$BASTION_ARCH" == "x86_64" || "$BASTION_ARCH" == "arm64" ]] \
    || die "不支持的架构 $BASTION_ARCH ($BASTION_INSTANCE_TYPE)"
  offered_in_any "$BASTION_INSTANCE_TYPE" "${azs[@]}" || die "$BASTION_INSTANCE_TYPE 在 ${azs[*]} 都没有供应，请换机型"
  ok "跳板机机型: $BASTION_INSTANCE_TYPE ($BASTION_ARCH, ${vcpu} vCPU, $((mem / 1024))GiB)"

  if [[ -n "$deployed" && "$deployed" != "$BASTION_INSTANCE_TYPE" ]]; then
    warn "机型从 $deployed 变更为 $BASTION_INSTANCE_TYPE: 跳板机实例会被替换 (EIP 不变)"
    warn "  - 跳板机本地文件会丢失 (请先把需要的文件存到 S3)"
    warn "  - SSH host key 会变化，本机需删除旧记录: ssh-keygen -R <EIP>"
    confirm "确认替换跳板机?" || exit 0
  fi
}

# AL2023 AMI 的 SSM 公共参数 (随架构)
bastion_ami_param() {
  printf '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-%s' "$BASTION_ARCH"
}
