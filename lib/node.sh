#!/usr/bin/env bash
# shellcheck disable=SC2034  # LAUNCH_* 变量由 lib/instance.sh 读取
# 裸 GPU 机器 (gpu-node): 栈参数、user-data、启动参数、信息输出

NODE_ROLE_TAG="gpu-node"

node_stack_name() { printf '%s-node-%s' "$PROJECT_NAME" "$1"; }

validate_node_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{1,15}$ ]] \
    || die "节点名只能包含小写字母/数字/-，以字母开头，长度 2-16: '$1'"
}

node_instances() {  # node_instances <name> [states]
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Role,Values=$NODE_ROLE_TAG" \
              "Name=tag:Node,Values=$1" \
              "Name=instance-state-name,Values=${2:-pending,running,stopping,stopped}" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# 同 VPC 的跳板机 SG (不同 VPC 不能引用)
bastion_sg_for_vpc() {
  stack_ready "$BASTION_STACK" || return 0
  local sg vpc
  sg="$(stack_output "$BASTION_STACK" BastionSecurityGroupId)"
  vpc="$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].VpcId' --output text 2>/dev/null || true)"
  if [[ "$vpc" == "$1" ]]; then printf '%s' "$sg"; fi   # 用 if: 不同 VPC 时也要返回 0 (调用方在 set -e 下赋值)
}

# node_stack_params -> 每行一个 Key=Value
node_stack_params() {
  local ports=() i
  read -ra ports <<<"$NODE_SERVICE_PORTS"
  printf '%s\n' "ProjectName=$PROJECT_NAME" "NodeName=$NODE_NAME" "VpcId=$NODE_VPC_ID" \
    "VpcCidr=$NODE_VPC_CIDR" "BastionSecurityGroupId=$NODE_BASTION_SG" \
    "EnableNlb=$([[ "$WITH_NLB" == "1" ]] && echo true || echo false)" \
    "NlbSubnetIds=${NODE_NLB_SUBNETS:-$NODE_SUBNET_ID}"
  if [[ "$WITH_NLB" == "1" ]]; then
    printf '%s\n' "NlbPortMin=$(printf '%s\n' "${ports[@]}" | sort -n | head -1)" \
                  "NlbPortMax=$(printf '%s\n' "${ports[@]}" | sort -n | tail -1)"
  fi
  for i in 1 2 3 4 5; do printf 'ServicePort%d=%s\n' "$i" "${ports[i-1]:-}"; done
  cidr_slot_params NodeCidr 5 "${NODE_ALLOWED_CIDRS:-}"
}

render_node_env() {
  printf 'AWS_REGION=%q\nNODE_NAME=%q\nNODE_DOCKER_ON_NVME=%q\nGPU_S3_BUCKETS=%q\nNODE_SERVICE_PORTS=%q\n' \
    "$AWS_REGION" "$NODE_NAME" "$NODE_DOCKER_ON_NVME" "$NODE_BUCKETS" "$NODE_SERVICE_PORTS"
}

# 裸 GPU 机器的 user-data: 只做 NVMe / Docker / GPU 环境准备，不部署任何模型
render_node_user_data() {
  local out="$1"
  {
    printf '#!/bin/bash\nset -euo pipefail\nexec > >(tee -a /var/log/gpu-node-userdata.log) 2>&1\n'
    printf 'install -d -m 755 /etc/gpu-node /opt/gpu-node\n'
    printf "cat >/etc/gpu-node/node.env <<'__ENV__'\n%s\n__ENV__\n" "$(render_node_env)"
    printf "cat >/opt/gpu-node/node-init.sh <<'__INIT__'\n%s\n__INIT__\nchmod 755 /opt/gpu-node/node-init.sh\n" \
      "$(cat "$ROOT_DIR/instance/node-init.sh")"
    cat <<'__SETUP__'
command -v docker >/dev/null 2>&1 || { echo "Docker 未安装，请使用 Deep Learning AMI"; exit 1; }
cat >/etc/systemd/system/gpu-node-init.service <<'__UNIT__'
[Unit]
Description=GPU node init (NVMe RAID0 / Docker data-root)
After=network-online.target local-fs.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/gpu-node/node-init.sh
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target docker.service
__UNIT__
cat >/etc/profile.d/gpu-node.sh <<'__PROFILE__'
set -a; . /etc/gpu-node/node.env; set +a
export AWS_DEFAULT_REGION="$AWS_REGION" NVME_DIR=/mnt/nvme
__PROFILE__
systemctl daemon-reload
systemctl enable gpu-node-init.service docker.service
# 首次启动时 Docker 已在运行: 停止 -> 初始化 (可能修改 data-root) -> 启动
systemctl stop docker.socket docker.service 2>/dev/null || true
systemctl start gpu-node-init.service
systemctl start docker.service
docker info --format 'Docker {{.ServerVersion}} data-root={{.DockerRootDir}} runtimes={{range $k,$v := .Runtimes}}{{$k}} {{end}}'
echo "gpu-node ready: $(tr '\n' ' ' </var/log/gpu-node-ready)"
__SETUP__
  } | gzip -9 >"$out"
  (( $(wc -c <"$out") < 16384 )) || die "user-data 超过 16KB 限制"
}

# 设置 LAUNCH_* 覆盖默认的 vLLM 启动参数
configure_node_launch() {
  local azs="${1:-}"
  LAUNCH_PREFERRED_SUBNET="$NODE_SUBNET_ID"
  if [[ "$NODE_SUBNET_FALLBACK" == "1" ]]; then
    LAUNCH_SUBNET_IDS="$(sibling_subnets "$azs")"
  else
    LAUNCH_SUBNET_IDS="$NODE_SUBNET_ID"
  fi
  [[ -n "$LAUNCH_SUBNET_IDS" ]] || die "没有可用于创建实例的子网 (NLB 模式下实例 AZ 需有公有子网)"
  LAUNCH_SG_IDS="$(stack_output "$NODE_STACK" NodeSecurityGroupId)"
  # 所有 GPU 机器共用推理栈的 Instance Profile
  LAUNCH_PROFILE="$(stack_output "$INFERENCE_STACK" InstanceProfileName)"
  LAUNCH_ROLE_TAG="$NODE_ROLE_TAG"
  LAUNCH_NAME="$NODE_STACK"
  LAUNCH_EXTRA_TAGS="{Key=Node,Value=$NODE_NAME}"
  LAUNCH_HOP_LIMIT="$NODE_IMDS_HOP_LIMIT"
  LAUNCH_ROOT_GB="$NODE_ROOT_VOLUME_GB"
  LAUNCH_PUBLIC_IP="$([[ "$NODE_SUBNET_PUBLIC" == "true" ]] && echo 1 || echo 0)"
  LAUNCH_USER_DATA_FN=render_node_user_data
}

register_node_targets() {
  local iid="$1" i arn
  aws ec2 wait instance-running --instance-ids "$iid"
  for i in 1 2 3 4 5; do
    arn="$(stack_output "$NODE_STACK" "TargetGroup${i}Arn")"
    [[ -n "$arn" && "$arn" != "None" ]] || continue
    aws elbv2 register-targets --target-group-arn "$arn" --targets "Id=$iid"
  done
  ok "已注册到 NLB target groups"
}

print_node_info() {
  local iid="$1" ip key bastion_ip="" dns=""
  ip="$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  key="$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].KeyName' --output text)"
  stack_ready "$BASTION_STACK" && bastion_ip="$(stack_output "$BASTION_STACK" BastionPublicIp)"
  [[ "$WITH_NLB" == "1" ]] && dns="$(stack_output "$NODE_STACK" NlbDnsName)"
  local p ep=""
  for p in $NODE_SERVICE_PORTS; do ep+="${dns:+ $dns:$p}"; done
  cat >&2 <<EOF

================================ GPU 机器 ($NODE_NAME) ================================
 Instance  : $iid   私网 IP: $ip   子网: $NODE_SUBNET_ID
 SSM 登录  : aws ssm start-session --region $AWS_REGION --target $iid
$( [[ -n "$bastion_ip" && "$key" != "None" ]] && echo " SSH 登录  : ssh -i $SSH_KEY_DIR/$key.pem -J ec2-user@$bastion_ip ec2-user@$ip   (Ubuntu AMI 用户名为 ubuntu)")
 服务端口  : $NODE_SERVICE_PORTS (仅 VPC 内可访问，如 http://$ip:${NODE_SERVICE_PORTS%% *})
$( [[ -n "$dns" ]] && echo " 对外 NLB  :$ep  (来源: $NODE_ALLOWED_CIDRS，健康检查为 TCP，服务监听后变为 healthy)")
 S3 读写   : $NODE_BUCKETS
 数据目录  : /mnt/nvme (实例存储，stop/start 后清空)$( [[ "$NODE_DOCKER_ON_NVME" == "1" ]] && echo "；Docker 数据目录在 /mnt/nvme/docker")
 初始化日志: /var/log/gpu-node-userdata.log   就绪信息: /var/log/gpu-node-ready

 部署自定义服务示例 (端口需在 NODE_SERVICE_PORTS 中):
   docker run -d --gpus all --restart unless-stopped -p ${NODE_SERVICE_PORTS%% *}:${NODE_SERVICE_PORTS%% *} -v /mnt/nvme:/data <镜像>
 ⚠️ NLB 为 TCP 明文透传，鉴权 (API Key 等) 需由服务自身实现
==========================================================================================
EOF
}
