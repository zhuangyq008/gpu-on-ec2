#!/bin/bash
# 运行在裸 GPU 机器上 (gpu-node-init.service，每次开机在 docker.service 之前执行，幂等):
#   1. 实例存储 NVMe 组 RAID0 挂载到 /mnt/nvme (stop/start 后实例存储被清空，自动重建)
#   2. (可选) Docker 数据目录迁到 NVMe
#   3. 检查 NVIDIA Driver / Docker / NVIDIA Container Toolkit，结果写入 /var/log/gpu-node-ready
# NVMe 逻辑与 instance/prepare.sh 中的 setup_nvme 保持一致
set -euo pipefail
# shellcheck source=/dev/null
source /etc/gpu-node/node.env

log() { echo "[gpu-node-init] $(date -u +%FT%TZ) $*"; }
fail() { log "ERROR: $*"; exit 1; }

NVME_LABEL="llm-nvme"
NVME_MOUNT=/mnt/nvme

install_pkg() {
  if command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  else fail "无法安装依赖: $*"; fi
}

setup_nvme() {
  mountpoint -q "$NVME_MOUNT" && { log "$NVME_MOUNT 已挂载"; return; }
  mkdir -p "$NVME_MOUNT"
  # reboot 场景: 文件系统仍在，重新组装 / 挂载即可
  command -v mdadm >/dev/null 2>&1 && mdadm --assemble --scan >/dev/null 2>&1 || true
  local existing
  existing="$(blkid -L "$NVME_LABEL" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    mount -o noatime "$existing" "$NVME_MOUNT"
    log "已重新挂载 $existing -> $NVME_MOUNT"
    return
  fi
  local devs target
  mapfile -t devs < <(lsblk -dpn -o NAME,MODEL | awk '/Amazon EC2 NVMe Instance Storage/ {print $1}')
  case "${#devs[@]}" in
    0) log "WARN: 未发现实例存储 NVMe，$NVME_MOUNT 使用根卷"; return ;;
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

# 把 data-root 合并进 /etc/docker/daemon.json (保留 DLAMI 已有的 nvidia runtime 等配置)
docker_on_nvme() {
  [[ "${NODE_DOCKER_ON_NVME:-0}" == "1" ]] || return 0
  mountpoint -q "$NVME_MOUNT" || { log "WARN: NVMe 未挂载，Docker 数据目录保持在根卷"; return 0; }
  mkdir -p "$NVME_MOUNT/docker"
  python3 - "$NVME_MOUNT/docker" <<'PY'
import json, os, sys
path = "/etc/docker/daemon.json"
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        data = f.read()
    cfg = json.loads(data) if data.strip() else {}
if cfg.get("data-root") != sys.argv[1]:
    cfg["data-root"] = sys.argv[1]
    os.makedirs("/etc/docker", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)   # 原子替换，避免写一半导致 Docker 无法启动
PY
  log "Docker data-root -> $NVME_MOUNT/docker (stop/start 后镜像需重新拉取)"
}

write_ready_report() {
  local gpus runtime
  gpus="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | sort | uniq -c | xargs || echo "N/A")"
  runtime="no"
  command -v nvidia-ctk >/dev/null 2>&1 && runtime="yes"
  cat >/var/log/gpu-node-ready <<EOF
time=$(date -u +%FT%TZ)
node=$NODE_NAME
gpus=$gpus
nvme=$(df -h --output=size,target "$NVME_MOUNT" 2>/dev/null | tail -1 | xargs)
docker_on_nvme=${NODE_DOCKER_ON_NVME:-0}
nvidia_container_toolkit=$runtime
EOF
  log "就绪: $(tr '\n' ' ' </var/log/gpu-node-ready)"
}

main() {
  setup_nvme
  docker_on_nvme
  command -v nvidia-smi >/dev/null 2>&1 || fail "未发现 NVIDIA Driver，请使用 Deep Learning AMI"
  write_ready_report
}

main "$@"
