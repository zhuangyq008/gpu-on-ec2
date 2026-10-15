#!/usr/bin/env bash
# 公共函数: 日志、配置加载、交互、CloudFormation 封装
# shellcheck disable=SC2034

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
[[ -t 1 ]] || { C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; }

log()  { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# 非交互模式: ASSUME_YES=1 或命令行 -y/--yes
ASSUME_YES="${ASSUME_YES:-0}"

# AWS CloudShell: 会话无键盘输入约 20-30 分钟会被回收，长时间等待需可中断、可重跑
is_cloudshell() { [[ "${AWS_EXECUTION_ENV:-}" == "CloudShell" ]]; }

parse_common_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $arg (使用 --help 查看用法)" ;;
    esac
  done
}

load_config() {
  local cfg="${CONFIG_FILE:-$ROOT_DIR/config.env}"
  [[ -f "$cfg" ]] || die "找不到配置文件 $cfg"
  # shellcheck source=/dev/null
  source "$cfg"
  validate_config
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
  NETWORK_STACK="${PROJECT_NAME}-network"
  INFERENCE_STACK="${PROJECT_NAME}-inference"
  BASTION_STACK="${PROJECT_NAME}-bastion"
  OPS_KEY_NAME="${KEY_NAME:-${PROJECT_NAME}-ops}"
}

validate_config() {
  [[ "$PROJECT_NAME" =~ ^[a-z][a-z0-9-]{1,20}$ ]] \
    || die "PROJECT_NAME 只能包含小写字母/数字/-，以字母开头，长度 2-21: '$PROJECT_NAME'"
  [[ "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "AWS_REGION 格式错误: '$AWS_REGION'"
  [[ "$NAT_MODE" == "single" || "$NAT_MODE" == "per-az" ]] || die "NAT_MODE 只能是 single 或 per-az"
  # shellcheck disable=SC2015
  [[ "$LISTENER_PORT" =~ ^[0-9]+$ ]] && (( LISTENER_PORT > 0 && LISTENER_PORT < 65536 )) \
    || die "LISTENER_PORT 无效: '$LISTENER_PORT'"
  [[ "$VPC_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/16$ ]] || die "VPC_CIDR 必须是 /16: '$VPC_CIDR'"
  [[ "$MODEL_ID" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*/[A-Za-z0-9_-][A-Za-z0-9._-]*$ && "$MODEL_ID" != *..* ]] \
    || die "MODEL_ID 格式应为 org/name: '$MODEL_ID'"
  [[ "$MODEL_REVISION" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] || die "MODEL_REVISION 无效: '$MODEL_REVISION'"
  [[ "$MODEL_S3_PREFIX" =~ ^[A-Za-z0-9_-][A-Za-z0-9._/-]*[A-Za-z0-9_-]$ && "$MODEL_S3_PREFIX" != *..* ]] \
    || die "MODEL_S3_PREFIX 无效 (不能以 / 开头或结尾，不能包含 ..): '$MODEL_S3_PREFIX'"
  [[ -z "$HF_TOKEN_SECRET_ARN" || "$HF_TOKEN_SECRET_ARN" =~ ^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$ ]] \
    || die "HF_TOKEN_SECRET_ARN 不是合法的 Secrets Manager ARN"
  [[ -z "$AMI_ID" || "$AMI_ID" =~ ^ami-[0-9a-f]{8,17}$ ]] || die "AMI_ID 无效: '$AMI_ID'"
  [[ -z "$CAPACITY_RESERVATION_ID" || "$CAPACITY_RESERVATION_ID" =~ ^cr-[0-9a-f]{8,17}$ ]] \
    || die "CAPACITY_RESERVATION_ID 无效: '$CAPACITY_RESERVATION_ID'"
  local t
  for t in $DEFAULT_INSTANCE_TYPE $FALLBACK_INSTANCE_TYPES; do
    [[ "$t" =~ ^[a-z0-9-]+\.[a-z0-9-]+$ ]] || die "机型名称无效: '$t'"
  done
  [[ -z "$KEY_NAME" || "$KEY_NAME" =~ ^[A-Za-z0-9._-]{1,255}$ ]] || die "KEY_NAME 无效: '$KEY_NAME'"
  [[ -z "$BASTION_INSTANCE_TYPE" || "$BASTION_INSTANCE_TYPE" =~ ^[a-z0-9-]+\.[a-z0-9-]+$ ]] \
    || die "BASTION_INSTANCE_TYPE 无效"
  # shellcheck disable=SC2015
  [[ "$BASTION_ROOT_VOLUME_GB" =~ ^[0-9]+$ ]] && (( BASTION_ROOT_VOLUME_GB >= 30 )) \
    || die "BASTION_ROOT_VOLUME_GB 至少 30"
  local b
  for b in $OPS_EXTRA_BUCKETS; do
    [[ "$b" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "OPS_EXTRA_BUCKETS 中的 bucket 名无效: '$b'"
  done
  for b in $NODE_S3_BUCKETS; do
    [[ "$b" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "NODE_S3_BUCKETS 中的 bucket 名无效: '$b'"
  done
  local p nports=0 seen=" "
  for p in $NODE_SERVICE_PORTS; do
    # shellcheck disable=SC2015
    [[ "$p" =~ ^[1-9][0-9]{0,4}$ ]] && (( p <= 65535 && p != 22 )) \
      || die "NODE_SERVICE_PORTS 中的端口无效: '$p' (1-65535，不能是 22，不能有前导零)"
    [[ "$seen" != *" $p "* ]] || die "NODE_SERVICE_PORTS 中端口重复: $p"
    seen+="$p "; nports=$((nports + 1))
  done
  (( nports <= 5 )) || die "NODE_SERVICE_PORTS 最多 5 个"
  # shellcheck disable=SC2015
  [[ "$NODE_ROOT_VOLUME_GB" =~ ^[0-9]+$ ]] && (( NODE_ROOT_VOLUME_GB >= 100 )) || die "NODE_ROOT_VOLUME_GB 至少 100"
  [[ "$NODE_IMDS_HOP_LIMIT" =~ ^[12]$ ]] || die "NODE_IMDS_HOP_LIMIT 只能是 1 或 2"
  [[ "$NODE_DOCKER_ON_NVME" =~ ^[01]$ && "$NODE_SUBNET_FALLBACK" =~ ^[01]$ ]] \
    || die "NODE_DOCKER_ON_NVME / NODE_SUBNET_FALLBACK 只能是 0 或 1"
  [[ "$CAPACITY_RETRY_ROUNDS" =~ ^[1-9][0-9]*$ && "$CAPACITY_RETRY_INTERVAL_SEC" =~ ^[0-9]+$ ]] \
    || die "CAPACITY_RETRY_ROUNDS / CAPACITY_RETRY_INTERVAL_SEC 必须是整数"
  [[ -z "$MODEL_BUCKET" || "$MODEL_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
    || die "MODEL_BUCKET 不是合法的 bucket 名称: '$MODEL_BUCKET'"
  [[ "$VLLM_MAX_MODEL_LEN" =~ ^[0-9]+$ ]] || die "VLLM_MAX_MODEL_LEN 必须是整数"
  [[ "$VLLM_GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] || die "VLLM_GPU_MEMORY_UTILIZATION 必须在 (0,1) 之间"
  [[ "$VLLM_TENSOR_PARALLEL_SIZE" == "auto" || "$VLLM_TENSOR_PARALLEL_SIZE" =~ ^[1-9][0-9]*$ ]] \
    || die "VLLM_TENSOR_PARALLEL_SIZE 必须是 auto 或正整数"
  # shellcheck disable=SC2015
  [[ "$ROOT_VOLUME_GB" =~ ^[0-9]+$ ]] && (( ROOT_VOLUME_GB >= 100 )) || die "ROOT_VOLUME_GB 至少 100"
  [[ "$VLLM_IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "VLLM_IMAGE 无效: '$VLLM_IMAGE'"
  # 额外参数会在实例上被拆分为 argv，禁止 $ ` ; | & < > ( ) 等 shell 元字符
  local extra_re='^[][A-Za-z0-9 ._=:,/{}"+-]*$'
  [[ "$VLLM_EXTRA_ARGS" =~ $extra_re ]] || die "VLLM_EXTRA_ARGS 含有不允许的字符"
}

require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "缺少依赖命令: ${missing[*]}"
}

check_prereqs() {
  require_cmds aws jq curl gzip
  local ver
  ver="$(aws --version 2>&1 | sed -n 's#^aws-cli/\([0-9]*\)\..*#\1#p')"
  [[ "$ver" == "2" ]] || die "需要 AWS CLI v2 (当前: $(aws --version 2>&1))"
  local ident
  ident="$(aws sts get-caller-identity --output json 2>/dev/null)" || die "AWS 凭证无效，请先配置 (aws configure / SSO / role)"
  ACCOUNT_ID="$(jq -r .Account <<<"$ident")"
  log "AWS 账号: $ACCOUNT_ID  身份: $(jq -r .Arn <<<"$ident")  Region: $AWS_REGION"
  local opt
  opt="$(aws ec2 describe-regions --all-regions --region us-east-1 \
          --query "Regions[?RegionName=='$AWS_REGION'].OptInStatus | [0]" --output text 2>/dev/null || true)"
  [[ "$opt" == "not-opted-in" ]] && die "Region $AWS_REGION 尚未开通，请在 Account 设置中启用"
  return 0
}

# confirm "问题" -> 0=yes
confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local ans
  read -r -p "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# prompt_default "提示" "默认值" -> stdout
prompt_default() {
  local ans
  if [[ "$ASSUME_YES" == "1" ]]; then printf '%s' "$2"; return; fi
  read -r -p "$1 [$2]: " ans
  printf '%s' "${ans:-$2}"
}

# 从编号菜单中选择: choose_index "提示" 默认编号 条目数 -> stdout 编号(1-based)
choose_index() {
  local prompt="$1" def="$2" max="$3" ans
  if [[ "$ASSUME_YES" == "1" ]]; then printf '%s' "$def"; return; fi
  while true; do
    read -r -p "$prompt [默认 $def]: " ans
    ans="${ans:-$def}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= max )); then printf '%s' "$ans"; return; fi
    warn "请输入 1-$max 之间的编号"
  done
}

stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND"
}

# 栈可用 (创建/更新成功，或更新失败已回滚到上一个可用版本)
stack_ready() {
  [[ "$(stack_status "$1")" =~ ^(CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE)$ ]]
}

# 栈正在变更中时等待结束 (CloudShell 会话中断后重跑的场景)
wait_stack_settled() {
  local stack="$1" status
  while true; do
    status="$(stack_status "$stack")"
    [[ "$status" == *_IN_PROGRESS ]] || { printf '%s' "$status"; return; }
    log "栈 $stack 当前状态 $status，等待完成..."
    sleep 20
  done
}

# GPU 实例终止常超过 10 分钟 (CLI waiter 的默认上限)，这里自行轮询，最长 30 分钟
wait_terminated() {
  local start left
  start="$(date +%s)"
  log "等待实例终止: $* (GPU 实例通常需要 5-15 分钟)"
  while true; do
    left="$(aws ec2 describe-instances --instance-ids "$@" \
      --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId" --output text)"
    [[ -z "$left" ]] && return 0
    (( $(date +%s) - start < 1800 )) || die "等待超时，仍未终止: $left (稍后重新执行)"
    sleep 20
  done
}

stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text
}

# deploy_stack <stack> <template> [Key=Value ...]
# DEPLOY_STACK_NO_DIE=1 时失败返回 1 (由调用方决定是否重试)，失败原因存入 DEPLOY_STACK_ERROR
deploy_stack() {
  local stack="$1" tpl="$2"; shift 2
  local status
  status="$(wait_stack_settled "$stack")"
  if [[ "$status" == "ROLLBACK_COMPLETE" || "$status" == "ROLLBACK_FAILED" || "$status" == "DELETE_FAILED" ]]; then
    warn "栈 $stack 处于 ROLLBACK_COMPLETE，先删除后重建"
    aws cloudformation delete-stack --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --stack-name "$stack"
  fi
  log "部署 CloudFormation 栈 $stack ..."
  if ! aws cloudformation deploy \
      --stack-name "$stack" \
      --template-file "$tpl" \
      --capabilities CAPABILITY_NAMED_IAM \
      --no-fail-on-empty-changeset \
      --tags "Project=$PROJECT_NAME" \
      --parameter-overrides "$@"; then
    DEPLOY_STACK_ERROR="$(aws cloudformation describe-stack-events --stack-name "$stack" --max-items 30 \
      --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" \
      --output text 2>/dev/null || true)"
    printf '%s\n' "$DEPLOY_STACK_ERROR" | head -5 | cut -c1-300 >&2
    [[ "${DEPLOY_STACK_NO_DIE:-0}" == "1" ]] && return 1
    die "栈 $stack 部署失败"
  fi
  ok "栈 $stack 就绪"
}
