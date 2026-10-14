#!/usr/bin/env bash
# GPU 机型发现: 机型规格 + 各 AZ 供应情况 + 配额 + (可选) 容量参考分

# 结果缓存为 JSON 数组:
# [{type, gpus, gpuName, gpuMemGiB, vcpus, memGiB, nvmeGB, azs:[...]}]
GPU_CATALOG_JSON=""

# build_gpu_catalog "g6 g6e" -> 填充 GPU_CATALOG_JSON
build_gpu_catalog() {
  local families="$1" fam values=()
  for fam in $families; do
    [[ "$fam" =~ ^[a-z][a-z0-9-]*$ ]] || die "INSTANCE_FAMILIES 中的家族名无效: '$fam'"
    values+=("${fam}.*")
  done
  local filter
  filter="Name=instance-type,Values=$(IFS=,; echo "${values[*]}")"

  local offers specs
  offers="$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
              --filters "$filter" --output json)" || die "查询 instance-type-offerings 失败"
  specs="$(aws ec2 describe-instance-types --filters "$filter" --output json)" \
    || die "查询 instance-types 失败"

  GPU_CATALOG_JSON="$(jq -n --argjson offers "$offers" --argjson specs "$specs" '
    ($offers.InstanceTypeOfferings
      | group_by(.InstanceType)
      | map({key: .[0].InstanceType, value: (map(.Location) | sort)})
      | from_entries) as $az
    | [ $specs.InstanceTypes[]
        | select(.GpuInfo != null)
        | {
            type: .InstanceType,
            gpus: (.GpuInfo.Gpus | map(.Count) | add),
            gpuName: (.GpuInfo.Gpus[0].Manufacturer + " " + .GpuInfo.Gpus[0].Name),
            gpuMemGiB: ((.GpuInfo.TotalGpuMemoryInMiB // 0) / 1024 | floor),
            vcpus: .VCpuInfo.DefaultVCpus,
            memGiB: (.MemoryInfo.SizeInMiB / 1024 | floor),
            nvmeGB: (.InstanceStorageInfo.TotalSizeInGB // 0),
            azs: ($az[.InstanceType] // [])
          }
        | select(.azs | length > 0) ]
    | sort_by((.type | split(".")[0]), .gpus, .vcpus)')"
}

gpu_catalog_count() { jq 'length' <<<"$GPU_CATALOG_JSON"; }
gpu_catalog_get()   { jq -c --arg t "$1" '.[] | select(.type == $t)' <<<"$GPU_CATALOG_JSON"; }

# 对应的 On-Demand vCPU 配额代码
quota_code_for_type() {
  case "$1" in
    g*|vt*) echo "L-DB2E81BA" ;;   # Running On-Demand G and VT instances
    p*)     echo "L-417A185B" ;;   # Running On-Demand P instances
    *)      echo "L-1216C47A" ;;   # Running On-Demand Standard instances
  esac
}

get_vcpu_quota() {
  { aws service-quotas get-service-quota --service-code ec2 --quota-code "$(quota_code_for_type "$1")" \
      --query 'Quota.Value' --output text 2>/dev/null || true; } | cut -d. -f1
}

# 基于 Spot Placement Score 的容量参考分 (1-10，仅供参考，不代表 On-Demand 一定有货)
# 输出: {"ap-southeast-5a": 3, ...}
get_capacity_scores() {
  local itype="$1" az_map raw
  az_map="$(aws ec2 describe-availability-zones --output json \
              --query 'AvailabilityZones[].{id:ZoneId,name:ZoneName}')" || { echo '{}'; return; }
  raw="$(aws ec2 get-spot-placement-scores --region us-east-1 --instance-types "$itype" \
          --target-capacity 1 --single-availability-zone --region-names "$AWS_REGION" \
          --output json 2>/dev/null)" || { echo '{}'; return; }
  jq -n --argjson m "$az_map" --argjson r "$raw" '
    ($m | map({key: .id, value: .name}) | from_entries) as $n
    | ($r.SpotPlacementScores // []) | map(select($n[.AvailabilityZoneId] != null)
        | {key: $n[.AvailabilityZoneId], value: .Score}) | from_entries' 2>/dev/null || echo '{}'
}

# print_gpu_table [with_scores=0]  打印编号表格
print_gpu_table() {
  local with_scores="${1:-0}" i=0 row t scores
  local quota
  printf '\n%-4s %-15s %-5s %-14s %-9s %-6s %-8s %-9s %s\n' \
    "#" "InstanceType" "GPUs" "GPU" "GPU显存" "vCPU" "内存" "NVMe" "可用 AZ" >&2
  printf '%s\n' "---------------------------------------------------------------------------------------------------" >&2
  while IFS= read -r row; do
    i=$((i + 1))
    t="$(jq -r .type <<<"$row")"
    local azs
    azs="$(jq -r '.azs | join(",")' <<<"$row")"
    if [[ "$with_scores" == "1" ]]; then
      scores="$(get_capacity_scores "$t")"
      azs="$(jq -r --argjson s "$scores" '.azs | map(. + "(" + (($s[.] // "-") | tostring) + ")") | join(",")' <<<"$row")"
    fi
    printf '%-4s %-15s %-5s %-27s %-9s %-6s %-8s %-9s %s\n' "$i" "$t" \
      "$(jq -r .gpus <<<"$row")" "$(jq -r .gpuName <<<"$row")" \
      "$(jq -r .gpuMemGiB <<<"$row")GiB" "$(jq -r .vcpus <<<"$row")" \
      "$(jq -r .memGiB <<<"$row")GiB" "$(jq -r .nvmeGB <<<"$row")GB" "$azs" >&2
  done < <(jq -c '.[]' <<<"$GPU_CATALOG_JSON")
  quota="$(get_vcpu_quota g6.xlarge)"
  printf '\nOn-Demand G/VT vCPU 配额 (%s): %s\n' "$AWS_REGION" "${quota:-未知}" >&2
  [[ "$with_scores" == "1" ]] && printf 'AZ 后括号内为容量参考分 (1-10，基于 Spot Placement Score，仅供参考)\n' >&2
  printf '\n' >&2
}

# select_instance_type -> 设置 INSTANCE_TYPE
select_instance_type() {
  local n def_idx idx
  n="$(gpu_catalog_count)"
  (( n > 0 )) || die "在 $AWS_REGION 没有找到 [$INSTANCE_FAMILIES] 家族的 GPU 机型"
  print_gpu_table "${SHOW_CAPACITY_SCORE:-0}"
  def_idx="$(jq --arg t "$DEFAULT_INSTANCE_TYPE" 'map(.type) | index($t) // 0 | . + 1' <<<"$GPU_CATALOG_JSON")"
  idx="$(choose_index "请选择 GPU 机型编号" "$def_idx" "$n")"
  INSTANCE_TYPE="$(jq -r --argjson i "$((idx - 1))" '.[$i].type' <<<"$GPU_CATALOG_JSON")"
  ok "已选择机型: $INSTANCE_TYPE"
  check_quota_for "$INSTANCE_TYPE"
}

check_quota_for() {
  local itype="$1" need quota
  need="$(jq -r .vcpus <<<"$(gpu_catalog_get "$itype")")"
  quota="$(get_vcpu_quota "$itype")"
  if [[ -n "$quota" && "$quota" =~ ^[0-9]+$ && -n "$need" ]] && (( quota < need )); then
    warn "$itype 需要 $need vCPU，但配额只有 $quota。请在 Service Quotas 申请提升 ($(quota_code_for_type "$itype"))"
    confirm "仍然继续?" || exit 1
  fi
}

# 估算模型权重大小 (GiB)，取不到返回空
estimate_model_size_gib() {
  local url="https://huggingface.co/api/models/$MODEL_ID/revision/$MODEL_REVISION?blobs=true"
  curl -fsS --max-time 15 "$url" 2>/dev/null \
    | jq -r '[.siblings[]? | select(.rfilename | test("\\.(safetensors|bin|pt)$")) | .size // 0] | add // 0
             | . / 1073741824 | floor' 2>/dev/null || true
}

# 显存粗略检查: 权重需 < 总显存 * 利用率 * 0.85 (留出 KV cache / 激活)
check_gpu_memory_fit() {
  local itype="$1" size mem
  size="$(estimate_model_size_gib)"
  mem="$(jq -r .gpuMemGiB <<<"$(gpu_catalog_get "$itype")")"
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$mem" =~ ^[0-9]+$ ]] || return 0
  log "模型 $MODEL_ID 权重约 ${size}GiB，$itype 总显存 ${mem}GiB"
  if (( size * 100 > mem * 75 )); then
    warn "显存可能不足以加载模型并保留 KV cache，建议选择更大机型或量化版本"
    confirm "仍然继续?" || exit 1
  fi
}
