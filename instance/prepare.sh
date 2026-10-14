#!/bin/bash
# 运行在 GPU 实例上 (vllm.service ExecStartPre)，幂等，每次启动 vLLM 前执行:
#   1. 将实例存储 NVMe 组成 RAID0 并挂载 (stop/start 后实例存储会被清空，需重建)
#   2. 准备模型权重: 本地已就绪 -> 跳过; S3 已有 -> 从 S3 同步; 否则 -> 从 Hugging Face 下载并回灌 S3
set -euo pipefail
# shellcheck source=/dev/null
source /etc/llm/llm.env

log() { echo "[llm-prepare] $(date -u +%FT%TZ) $*"; }
fail() { log "ERROR: $*"; exit 1; }

NVME_LABEL="llm-nvme"
S3_MARKER="_LLM_COMPLETE"
LOCAL_MARKER=".llm_complete"

install_pkg() {
  if command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  else fail "无法安装依赖: $*"; fi
}

instance_store_devices() {
  lsblk -dpn -o NAME,MODEL | awk '/Amazon EC2 NVMe Instance Storage/ {print $1}'
}

setup_nvme() {
  # DLAMI 自带的 dlami-nvme 服务会把实例存储挂到 /opt/dlami/nvme，优先复用
  if systemctl list-unit-files dlami-nvme.service >/dev/null 2>&1; then
    for _ in $(seq 1 30); do mountpoint -q /opt/dlami/nvme && break; sleep 2; done
  fi
  if mountpoint -q /opt/dlami/nvme; then
    NVME_MOUNT=/opt/dlami/nvme
    log "复用 DLAMI 挂载的实例存储 $NVME_MOUNT ($(df -h --output=size "$NVME_MOUNT" | tail -1 | tr -d ' '))"
    return
  fi

  NVME_MOUNT=/mnt/nvme
  mountpoint -q "$NVME_MOUNT" && { log "$NVME_MOUNT 已挂载"; return; }
  mkdir -p "$NVME_MOUNT"

  # reboot 场景: 已有文件系统，只需重新组装/挂载
  command -v mdadm >/dev/null 2>&1 && mdadm --assemble --scan >/dev/null 2>&1 || true
  local existing
  existing="$(blkid -L "$NVME_LABEL" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    mount -o noatime "$existing" "$NVME_MOUNT"
    log "已重新挂载 $existing -> $NVME_MOUNT"
    return
  fi

  mapfile -t devs < <(instance_store_devices)
  local target
  case "${#devs[@]}" in
    0)
      log "WARN: 未发现实例存储 NVMe，模型将存放在根卷 /opt/llm/data"
      NVME_MOUNT=/opt/llm/data; mkdir -p "$NVME_MOUNT"; return ;;
    1) target="${devs[0]}" ;;
    *)
      command -v mdadm >/dev/null 2>&1 || install_pkg mdadm
      target=/dev/md/llm-nvme
      mdadm --create "$target" --run --level=0 --raid-devices="${#devs[@]}" "${devs[@]}"
      ;;
  esac
  command -v mkfs.xfs >/dev/null 2>&1 || install_pkg xfsprogs
  mkfs.xfs -f -L "$NVME_LABEL" "$target" >/dev/null
  mount -o noatime "$target" "$NVME_MOUNT"
  log "实例存储 ${devs[*]} -> $target -> $NVME_MOUNT ($(df -h --output=size "$NVME_MOUNT" | tail -1 | tr -d ' '))"
}

pull_image() {
  local i
  for i in 1 2 3 4 5; do
    docker pull -q "$VLLM_IMAGE" && return 0
    log "docker pull 失败，第 $i 次重试..."; sleep $((i * 15))
  done
  fail "无法拉取镜像 $VLLM_IMAGE"
}

hf_token() {
  [[ -n "${HF_TOKEN_SECRET_ARN:-}" ]] || return 0
  aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$HF_TOKEN_SECRET_ARN" \
    --query SecretString --output text
}

download_from_hf() {
  local dest="$1"
  log "S3 中没有权重，从 Hugging Face 下载 $MODEL_ID@$MODEL_REVISION ..."
  local token envfile
  token="$(hf_token)"
  envfile="$(mktemp /run/llm-hf.XXXXXX)"; chmod 600 "$envfile"
  HF_ENV_FILE="$envfile"   # 全局变量: EXIT trap 执行时局部变量已不在作用域
  trap 'rm -f "${HF_ENV_FILE:-}"' EXIT
  printf 'HF_TOKEN=%s\n' "$token" >"$envfile"
  # 复用 vLLM 镜像里的 huggingface_hub，主机无需安装 Python 依赖
  # 只下载 safetensors / 配置 / tokenizer，不下载 pickle 格式 (*.bin / *.pt) 权重
  docker run --rm --env-file "$envfile" \
    -e MODEL_ID="$MODEL_ID" -e MODEL_REVISION="$MODEL_REVISION" -e DEST=/dest \
    -v "$dest":/dest --entrypoint python3 "$VLLM_IMAGE" -c '
import os
from huggingface_hub import snapshot_download
snapshot_download(repo_id=os.environ["MODEL_ID"], revision=os.environ["MODEL_REVISION"],
                  local_dir=os.environ["DEST"], token=os.environ.get("HF_TOKEN") or None, max_workers=16,
                  allow_patterns=["*.safetensors", "*.json", "*.txt", "*.jinja", "*.model", "*.tiktoken"])
' || { rm -f "$envfile"; fail "Hugging Face 下载失败"; }
  rm -f "$envfile"
  rm -rf "$dest/.cache"
}

prepare_model() {
  local local_dir="$NVME_MOUNT/models/$MODEL_ID/$MODEL_REVISION"
  local s3_key_prefix="$MODEL_S3_PREFIX/$MODEL_ID/$MODEL_REVISION"
  local s3_uri="s3://$MODEL_BUCKET/$s3_key_prefix"
  mkdir -p "$local_dir"
  ln -sfn "$local_dir" /opt/llm/model   # run-vllm.sh 通过固定路径挂载

  if [[ -f "$local_dir/$LOCAL_MARKER" ]]; then
    log "本地权重已就绪: $local_dir"; return
  fi

  aws configure set default.s3.max_concurrent_requests 64
  aws configure set default.s3.multipart_chunksize 64MB

  # 用 ListObjectsV2 判断标记是否存在: 满足 IAM 的 s3:prefix 条件，且能区分 "不存在" 与 "调用失败"
  # 注意: CLI 自动分页会丢弃 KeyCount 字段，必须统计 Contents 长度
  local marker_count
  # shellcheck disable=SC2016  # JMESPath 字面量，非 shell 展开
  marker_count="$(aws s3api list-objects-v2 --region "$AWS_REGION" --bucket "$MODEL_BUCKET" \
                    --prefix "$s3_key_prefix/$S3_MARKER" --query 'length(Contents || `[]`)' --output text)" \
    || fail "无法访问 s3://$MODEL_BUCKET/$s3_key_prefix (检查 IAM / bucket policy)"
  if [[ "$marker_count" =~ ^[1-9] ]]; then
    log "从 $s3_uri 同步权重到 NVMe ..."
    aws s3 sync --region "$AWS_REGION" --only-show-errors --exclude "$S3_MARKER" "$s3_uri" "$local_dir"
  else
    download_from_hf "$local_dir"
    log "上传权重到 $s3_uri ..."
    aws s3 sync --region "$AWS_REGION" --only-show-errors \
      --exclude "$LOCAL_MARKER" --exclude ".cache/*" "$local_dir" "$s3_uri"
    printf 'model=%s\nrevision=%s\nuploaded=%s\n' "$MODEL_ID" "$MODEL_REVISION" "$(date -u +%FT%TZ)" \
      | aws s3 cp --region "$AWS_REGION" - "$s3_uri/$S3_MARKER"
  fi
  touch "$local_dir/$LOCAL_MARKER"
  log "权重就绪: $local_dir ($(du -sh "$local_dir" | cut -f1))"
}

main() {
  setup_nvme
  pull_image
  prepare_model
}

main "$@"
