#!/bin/bash
# shellcheck disable=SC2153  # 变量来自 /etc/llm/llm.env
# 运行在 GPU 实例上 (vllm.service ExecStart): 以前台方式运行 vLLM 容器
set -euo pipefail
# shellcheck source=/dev/null
source /etc/llm/llm.env

log() { echo "[run-vllm] $(date -u +%FT%TZ) $*"; }

MODEL_DIR="$(readlink -f /opt/llm/model)"
[[ -f "$MODEL_DIR/config.json" ]] || { log "ERROR: $MODEL_DIR 中没有模型权重"; exit 1; }

GPU_COUNT="$(nvidia-smi -L | grep -c '^GPU ')"
TP="$VLLM_TENSOR_PARALLEL_SIZE"
[[ "$TP" == "auto" ]] && TP="$GPU_COUNT"

# API key 只写入 tmpfs (/run)，不落盘、不出现在进程参数中
install -d -m 700 /run/llm
API_KEY="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
            --secret-id "$API_KEY_SECRET_ARN" --query SecretString --output text)"
umask 077
printf 'VLLM_API_KEY=%s\nHF_HUB_OFFLINE=1\n' "$API_KEY" >/run/llm/vllm.env
unset API_KEY

# VLLM_EXTRA_ARGS 已在部署端校验 (无 shell 元字符)，这里再次校验后拆分为 argv
extra_re='^[][A-Za-z0-9 ._=:,/{}"+-]*$'
[[ "$VLLM_EXTRA_ARGS" =~ $extra_re ]] || { log "ERROR: VLLM_EXTRA_ARGS 含非法字符"; exit 1; }
eval "EXTRA_ARGS=($VLLM_EXTRA_ARGS)"

INSTANCE_ID="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || hostname)"
docker rm -f vllm >/dev/null 2>&1 || true

log "启动 vLLM: model=$MODEL_ID tp=$TP max_len=$VLLM_MAX_MODEL_LEN gpus=$GPU_COUNT"
exec docker run --name vllm --rm \
  --gpus all --ipc=host --security-opt no-new-privileges \
  -p 8000:8000 \
  --env-file /run/llm/vllm.env \
  -v "$MODEL_DIR":/model:ro \
  --log-driver awslogs \
  --log-opt awslogs-region="$AWS_REGION" \
  --log-opt awslogs-group="$LOG_GROUP" \
  --log-opt awslogs-stream="$INSTANCE_ID" \
  --entrypoint vllm \
  "$VLLM_IMAGE" \
  serve /model \
  --served-model-name "$MODEL_ID" \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size "$TP" \
  --max-model-len "$VLLM_MAX_MODEL_LEN" \
  --gpu-memory-utilization "$VLLM_GPU_MEMORY_UTILIZATION" \
  "${EXTRA_ARGS[@]}"
