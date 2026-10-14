#!/usr/bin/env bash
# Deep Learning AMI 发现与选择

# list_dlamis -> stdout JSON [{id, name, family, date}] 每个 AMI 系列只保留最新版本
list_dlamis() {
  local raw
  raw="$(aws ec2 describe-images --owners amazon \
          --filters "Name=name,Values=$AMI_NAME_FILTER" "Name=state,Values=available" \
                    "Name=architecture,Values=x86_64" \
          --query 'Images[].{id:ImageId,name:Name,date:CreationDate}' --output json)" \
    || die "查询 DLAMI 失败"
  # 按 "类型(Base/PyTorch) + OS" 分组，每组只保留最新一个 (PyTorch 取最高版本);
  # 排除 Ubuntu Pro (额外收费)、Amazon Linux 2 (EOL)、TensorFlow，以及 90 天内无更新的系列
  local cutoff
  cutoff="$(date -u -d '-90 days' +%Y-%m-%d 2>/dev/null || date -u -v-90d +%Y-%m-%d)"
  jq --arg cutoff "$cutoff" '[ .[]
        | select(.name | test("Ubuntu Pro|Amazon Linux 2\\)|TensorFlow") | not)
        | select(.date >= $cutoff)
        | . + {
            kind: (if (.name | test("^Deep Learning Base")) then "Base" else "PyTorch" end),
            os: (.name | capture("\\((?<os>[^)]+)\\)").os // "unknown"),
            ver: ((.name | capture("PyTorch (?<v>[0-9.]+)").v // "0") | split(".") | map(tonumber))
          } ]
      | group_by(.kind + "|" + .os)
      | map(max_by([.ver, .date]))
      | sort_by(
          (if .kind == "Base" then 0 else 1 end),
          (if (.os | test("Amazon Linux 2023")) then 0 else 1 end),
          .os)
      | map({id, name, date})' <<<"$raw"
}

# select_ami -> 设置 AMI_ID / AMI_NAME
select_ami() {
  if [[ -n "$AMI_ID" ]]; then
    AMI_NAME="$(aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].Name' --output text)" \
      || die "AMI $AMI_ID 不存在或无权限"
    ok "使用指定 AMI: $AMI_ID ($AMI_NAME)"
    return
  fi
  local amis n i=0 row idx
  amis="$(list_dlamis)"
  n="$(jq length <<<"$amis")"
  (( n > 0 )) || die "在 $AWS_REGION 没有找到匹配 '$AMI_NAME_FILTER' 的 DLAMI"
  printf '\n%-4s %-22s %-12s %s\n' "#" "AMI ID" "发布日期" "名称" >&2
  printf '%s\n' "------------------------------------------------------------------------------------------------" >&2
  while IFS= read -r row; do
    i=$((i + 1))
    printf '%-4s %-22s %-12s %s\n' "$i" "$(jq -r .id <<<"$row")" \
      "$(jq -r '.date[0:10]' <<<"$row")" "$(jq -r .name <<<"$row")" >&2
  done < <(jq -c '.[]' <<<"$amis")
  printf '\n提示: vLLM 运行在 Docker 中，推荐使用 "Deep Learning Base OSS Nvidia Driver GPU AMI" (已含 Driver/Docker/NVIDIA Container Toolkit)\n\n' >&2
  idx="$(choose_index "请选择 AMI 编号" 1 "$n")"
  AMI_ID="$(jq -r --argjson i "$((idx - 1))" '.[$i].id' <<<"$amis")"
  AMI_NAME="$(jq -r --argjson i "$((idx - 1))" '.[$i].name' <<<"$amis")"
  ok "已选择 AMI: $AMI_ID ($AMI_NAME)"
}
