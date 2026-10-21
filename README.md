# GPU-on-EC2：在 AWS 马来西亚区域用 vLLM 部署 LLM 推理服务

一套 Bash + CloudFormation 脚本，在 **ap-southeast-5（马来西亚）** 自动完成以下工作：

- 创建 VPC，划分 public / private subnet（2 个 AZ）
- 列出 Region 内可用的 GPU 机型和 AZ，默认 **g6 全家族**，默认机型 **g6.12xlarge**
- 列出 Deep Learning AMI，交互式选择
- 跨 AZ（以及可选的备选机型）自动重试，抢占 GPU 容量
- 模型权重：首次从 Hugging Face 下载并存入 **S3**，之后每次启动都从 S3 拉到 **NVMe 实例存储**（RAID0）
- 用 **Docker 运行 vLLM**（OpenAI 兼容 API），默认模型 `Qwen/Qwen3.5-35B-A3B-FP8`
- **部署模型是可选的**：`deploy.sh` 开始时选择"GPU + 部署模型"、"只建裸 GPU 机器（不部署模型）"或"只建基础设施"
- 通过 **internet-facing NLB** 对外提供服务，鉴权方式为 API Key + 来源 CIDR 白名单

## 架构

```
                        Internet (仅 ALLOWED_CIDRS)
                                  │ TCP :8000
┌──────────────────────── VPC 10.50.0.0/16 ───────────────────────────────┐
│  ┌─ Public Subnet A ─────────┐      ┌─ Public Subnet B ─────────┐       │
│  │  NLB (SG: allowed CIDRs)  │      │  NLB (cross-zone)         │       │
│  │  NAT Gateway              │      │  [NAT Gateway] (per-az)   │       │
│  │  运维跳板机 (EIP) ◀── SSH(SSH_ALLOWED_CIDRS) / SSM                   │
│  │     └─ SSH :22 / vLLM :8000 ──▶ GPU EC2；读写模型 bucket             │
│  └────────────┬──────────────┘      └────────────┬──────────────┘       │
│               │ TCP :8000 (SG: 仅来自 NLB SG)      │                      │
│  ┌─ Private Subnet A ────────┐      ┌─ Private Subnet B ────────┐       │
│  │  GPU EC2 (g6.12xlarge)    │  或  │  GPU EC2 (按容量自动选 AZ) │       │
│  │  ├ Docker: vLLM           │      │                           │       │
│  │  └ NVMe RAID0: 模型权重    │      │                           │       │
│  └────────────┬──────────────┘      └───────────────────────────┘       │
│               │ S3 Gateway Endpoint (不经过 NAT)                         │
└───────────────┼─────────────────────────────────────────────────────────┘
                ▼
   S3: s3://<bucket>/models/<org>/<model>/<revision>/     Secrets Manager: API Key
   CloudWatch Logs: /<project>/vllm                        SSM Session Manager (无 SSH)
```

**权重加载流程**（每次 vLLM 启动前，由 `prepare.sh` 幂等执行）：

```
NVMe 已有权重 ──是──▶ 直接启动
    │否
S3 已有 _LLM_COMPLETE ──是──▶ aws s3 sync S3 → NVMe（走 Gateway Endpoint）
    │否
从 HF 下载 → NVMe → aws s3 sync NVMe → S3 → 写入 _LLM_COMPLETE 标记
```

> 实例存储在 **stop/start 之后会被清空**（reboot 不会）。脚本会自动重建 RAID0 并从 S3 重新拉取权重。

## 目录结构

```
.
├── config.env            # 全部可调参数 (可被同名环境变量覆盖)
├── deploy.sh             # 一键部署 (交互式)
├── list-gpu.sh           # 列出 GPU 机型 / AZ / 配额 / 容量参考分
├── launch-instance.sh    # 单独创建或替换 GPU 实例 (换机型 / AMI / 模型)
├── status.sh             # 查看状态，--test 做冒烟测试
├── deploy-bastion.sh     # 创建/更新运维跳板机 (SSH + SSM，可访问 GPU 实例和 S3)
├── gpu-node.sh           # 独立创建/列出/删除裸 GPU 机器 (不部署模型，供 OCR / Embedding 等使用)
├── destroy.sh            # 销毁全部资源 (S3 bucket、运维 key pair 保留)
├── cfn/
│   ├── network.yaml      # VPC / Subnets / IGW / NAT / S3 Endpoint
│   ├── inference.yaml    # NLB / SG / IAM / Secret / S3 / Logs
│   ├── bastion.yaml      # 运维跳板机 / EIP / SG 规则 / IAM
│   └── gpu-node.yaml     # 裸 GPU 机器的 IAM / SG / 可选 NLB
├── instance/             # 通过 user-data 下发到 EC2
│   ├── prepare.sh        # NVMe RAID0 + 权重准备
│   ├── run-vllm.sh       # docker run vLLM
│   ├── setup.sh          # 安装 systemd unit
│   └── node-init.sh      # 裸 GPU 机器初始化 (NVMe RAID0 / Docker data-root)
└── lib/                  # 部署端公共函数
```

## 前置条件

| 项目 | 要求 |
|---|---|
| 运行环境 | **推荐 AWS CloudShell**（已预装全部依赖）；或 Linux / macOS，bash 4+，`aws` CLI v2、`jq`、`curl`、`gzip` |
| Region | 账号已开通 `ap-southeast-5`（opt-in region） |
| 配额 | `Running On-Demand G and VT instances` 的 vCPU 配额 ≥ 机型 vCPU（g6.12xlarge 需要 48） |
| 权限 | CloudFormation、EC2、ELBv2、IAM（创建 role / instance profile）、S3、Secrets Manager、Logs、Service Quotas（只读） |

## 在 AWS CloudShell 中运行（推荐）

1. 用有部署权限的 IAM 身份登录控制台，Region 切换到 **Asia Pacific (Malaysia) ap-southeast-5**，然后打开 CloudShell。请使用默认的公网环境，不要用 VPC environment，因为脚本需要访问 GitHub 和 Hugging Face API。
2. 下载脚本：

   ```bash
   git clone https://github.com/zhuangyq008/gpu-on-ec2.git && cd gpu-on-ec2
   chmod +x *.sh          # 如果从 zip 包上传，需要恢复执行权限
   ```

3. **获取你本机的公网 IP**：CloudShell 的出口 IP 不是你本机的 IP。请在本机浏览器打开 <https://checkip.amazonaws.com>，把结果填到 `ALLOWED_CIDRS`（例如 `203.0.113.10/32`）。
4. 执行 `./deploy.sh`。

CloudShell 的注意事项：

- **会话超时**：大约 20–30 分钟没有键盘输入，CloudShell 会断开，正在运行的命令会被终止。
  - `deploy.sh` 在 CloudShell 中**不会**等待 vLLM 就绪。实例创建并注册到 NLB 后脚本就结束，实例会在后台自行完成初始化。
  - 如果中途断开，**直接重新执行 `./deploy.sh` 即可**。脚本会等待正在进行中的 CloudFormation 栈，跳过已经完成的步骤；已经有实例时不会重复创建。
  - `./launch-instance.sh --replace` 会一直等新实例 healthy。如果等待期间断开，旧实例会保留，等新实例 healthy 后执行 `./launch-instance.sh --retire-others <新实例ID>` 收尾。
- **区域变量**：CloudShell 会自动设置 `AWS_REGION`（指向当前控制台所在 Region），脚本不会读取它。部署目标 Region 由 `config.env` 或 `TARGET_REGION` 决定，所以在任意 Region 打开 CloudShell 都可以部署到马来西亚。
- 只有 `$HOME`（1GB）里的文件会持久保存，脚本本身只占几十 KB。

## 快速开始

```bash
# 1. (可选) 先看一下有哪些 GPU 机型、在哪些 AZ 有供应
./list-gpu.sh               # 默认 g6 家族
./list-gpu.sh g6 g6e g7e    # 多个家族一起看

# 2. 修改配置，至少设置 ALLOWED_CIDRS (允许访问推理服务的来源 IP)
vi config.env

# 3. 部署 (交互式选择部署内容、机型和 AMI)
./deploy.sh

# 4. 查看状态 + 冒烟测试
./status.sh --test
```

`deploy.sh` 第一步会询问本次部署内容（`DEPLOY_MODE`）：

| 编号 | 部署内容 | 等价参数 | 说明 |
|---|---|---|---|
| 1（默认） | GPU 实例 + 部署模型 `MODEL_ID` | `DEPLOY_MODE=vllm` | 默认 Qwen3.5-35B-A3B-FP8，经 NLB 提供 OpenAI 兼容 API |
| 2 | 裸 GPU 机器，**不部署模型** | `--no-model` / `DEPLOY_MODE=node` | 部署确认前先询问节点名（非交互模式为 `node1`）、是否为该机器创建对外 NLB（非交互模式用 `--with-nlb`）及其来源 CIDR；栈就绪后自动调用 `./gpu-node.sh create` 选择机型 / AMI / 子网（见"裸 GPU 机器"一节） |
| 3 | 只部署基础设施 | `--no-instance` / `DEPLOY_MODE=infra` | 只建网络栈与推理栈，之后再用 `./launch-instance.sh` 或 `./gpu-node.sh create` 创建 GPU 机器 |

> 选 2 / 3 时推理栈（NLB、API Key、共用 IAM Role、模型 bucket）照常创建，之后可以随时用 `./launch-instance.sh` 部署模型。
>
> 重新执行（例如 CloudShell 超时）：已存在 vLLM 实例且没有指定 `--no-model` / `DEPLOY_MODE` 时不再询问，只更新栈；选择裸 GPU 机器时，如果节点名已有实例，交互模式会要求换名，非交互模式只更新栈。

非交互部署（CI / 批量）：

```bash
ALLOWED_CIDRS="203.0.113.10/32" ./deploy.sh --yes                         # GPU + 部署模型
ALLOWED_CIDRS="203.0.113.10/32" ./deploy.sh --yes --no-model              # 裸 GPU 机器 (节点名 node1)
ALLOWED_CIDRS="203.0.113.10/32" NODE_ALLOWED_CIDRS="203.0.113.10/32" \
  ./deploy.sh --yes --no-model --with-nlb                                   # 裸 GPU 机器 + 对外 NLB
```

`deploy.sh` 结束时会打印 endpoint 和 API Key 的获取方式。首次启动需要拉取 vLLM 镜像（约 10GB）并从 HF 下载权重（FP8 约 35GB），一般需要 **15–40 分钟**；之后再重建实例时，权重直接从 S3 拉取，速度会快很多。

## 调用示例

```bash
# Secret ARN 见 ./status.sh 的输出 (栈输出 ApiKeySecretArn)
API_KEY=$(aws secretsmanager get-secret-value --region ap-southeast-5 \
  --secret-id <ApiKeySecretArn> --query SecretString --output text)
ENDPOINT=http://<NLB_DNS>:8000/v1

curl $ENDPOINT/chat/completions \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3.5-35B-A3B-FP8","messages":[{"role":"user","content":"你好"}],"max_tokens":512}'
```

> Qwen3.5 默认开启思考模式，思考内容在 `message.reasoning` 字段中。`max_tokens` 太小时，`content` 可能为空。不需要思考时，在请求体中加上 `"chat_template_kwargs": {"enable_thinking": false}`。

```python
from openai import OpenAI
client = OpenAI(base_url="http://<NLB_DNS>:8000/v1", api_key="<API_KEY>")
resp = client.chat.completions.create(
    model="Qwen/Qwen3.5-35B-A3B-FP8",
    messages=[{"role": "user", "content": "介绍一下马来西亚的制造业"}],
)
print(resp.choices[0].message.content)
```

## 主要配置（config.env）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TARGET_REGION` | `ap-southeast-5` | 部署 Region（**不要**用 `AWS_REGION` 覆盖） |
| `PROJECT_NAME` | `gpu-llm` | 资源命名前缀和 Tag |
| `DEPLOY_MODE` | 空（交互选择；`--yes` 时为 `vllm`） | `deploy.sh` 部署内容：`vllm` = GPU + 部署模型，`node` = 裸 GPU 机器（不部署模型），`infra` = 只建基础设施。命令行 `--add` / `--no-model` / `--no-instance` 优先 |
| `ALLOWED_CIDRS` | 空（重新执行时沿用已部署的值；非 CloudShell 环境下默认填入本机公网 IP） | NLB 来源白名单，逗号分隔，最多 10 个。在 `--yes` 模式下使用 `/0` 需要同时设置 `ALLOW_PUBLIC_CIDR=1` |
| `NAT_MODE` | `single` | `per-az` 表示每个 AZ 一个 NAT（高可用） |
| `INSTANCE_FAMILIES` | `g6` | 列出的 GPU 家族 |
| `DEFAULT_INSTANCE_TYPE` | `g6.12xlarge` | 默认机型 |
| `FALLBACK_INSTANCE_TYPES` | 空 | 主机型没有容量时依次尝试，例如 `g6.24xlarge` |
| `CAPACITY_RETRY_ROUNDS` / `_INTERVAL_SEC` | `3` / `60` | 所有 AZ 轮询的轮数 / 间隔 |
| `CAPACITY_RESERVATION_ID` | 空 | 使用已购买的 ODCR / Capacity Block |
| `AMI_ID` | 空 | 直接指定 AMI，跳过选择 |
| `MODEL_ID` | `Qwen/Qwen3.5-35B-A3B-FP8` | HF 模型 ID |
| `MODEL_BUCKET` | 空（自动创建 `<project>-models-<account>-<region>`） | 权重 bucket |
| `HF_TOKEN_SECRET_ARN` | 空 | gated 模型需要的 HF token secret（值为纯文本 token） |
| `VLLM_IMAGE` | `vllm/vllm-openai:v0.31.0` | 可替换为 ECR 镜像，避免 Docker Hub 限流 |
| `VLLM_MAX_MODEL_LEN` | `65536` | 最大上下文长度 |
| `VLLM_EXTRA_ARGS` | `--reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder` | 额外参数 |

### 模型与机型选择建议

| 模型 | 权重大小 | 推荐机型 | 说明 |
|---|---|---|---|
| `Qwen/Qwen3.5-35B-A3B-FP8`（默认） | ~34 GiB | g6.12xlarge（4×L4，共 89 GiB） | L4 原生支持 FP8，KV cache 空间充足 |
| `Qwen/Qwen3.5-35B-A3B`（BF16） | ~66 GiB | g6.48xlarge / g7e | 放在 g6.12xlarge 上 KV cache 不足，需要把 `VLLM_MAX_MODEL_LEN` 降到约 16K |

只需要文本能力时，可以在 `VLLM_EXTRA_ARGS` 里追加 `--language-model-only`，跳过视觉编码器，把显存留给 KV cache。

## 运维操作

| 场景 | 操作 |
|---|---|
| 换模型 / 机型 / AMI，零停机 | 修改 `config.env` → `./launch-instance.sh --replace`（新实例 healthy 后才下线旧实例） |
| 横向扩容 | `./launch-instance.sh` 或 `./deploy.sh --add`（新增一台，NLB 自动负载均衡） |
| 修改来源白名单 | 修改 `ALLOWED_CIDRS` → `./deploy.sh`（已有实例时只更新栈） |
| 登录实例 | `aws ssm start-session --target <instance-id>`，或经跳板机 SSH（见"运维跳板机"一节） |
| 只建基础设施 | `./deploy.sh --no-instance`（之后再用 `./launch-instance.sh` 创建 GPU 实例） |
| 只要 GPU 机器，不部署模型 | `./deploy.sh --no-model`（或交互选择 2），等同 `./deploy.sh --no-instance` + `./gpu-node.sh create` |
| 查看启动进度 | 实例上执行 `sudo journalctl -u vllm -f` |
| vLLM 日志 | CloudWatch Logs `/<project>/vllm`，或在实例上执行 `docker logs -f vllm` |
| 重启服务 | `sudo systemctl restart vllm` |
| 轮换 API Key | 在 Secrets Manager 中更新 secret → `sudo systemctl restart vllm` |
| 销毁 | `./destroy.sh`（S3 权重保留，下次部署自动复用） |

## 共用 GPU IAM Role

`deploy.sh`、`launch-instance.sh`、`gpu-node.sh` 创建的所有 GPU EC2 共用同一个 Role / Instance Profile：`<project>-gpu-instance-<region>`，由推理栈管理。

| 权限 | 说明 |
|---|---|
| `AmazonSSMManagedInstanceCore` | SSM 登录 |
| `AmazonEC2ContainerRegistryReadOnly` | 拉取 ECR 镜像 |
| S3 读 / 写 / 删 | 模型 bucket，以及 `GPU_S3_BUCKETS` 中列出的 bucket |
| Secrets Manager 读取 | vLLM API Key，以及配置了的 HF token |
| CloudWatch Logs 写入 | vLLM 日志组 |

- `GPU_S3_BUCKETS` 的更新规则：
  - `deploy.sh`：设置了这个变量时，按设置的值精确更新；留空时保持已部署的值不变。
  - `gpu-node.sh create`：只追加缺少的 bucket，不会删除已有的。
- ⚠️ 共用 Role 意味着所有 GPU 机器（包括客户在裸 GPU 机器上运行的容器）权限相同，**都能读取 vLLM API Key**。如果需要隔离，请拆分为不同的 `PROJECT_NAME`。
- 旧版本脚本创建的 gpu-node 机器使用的是独立 Role，可以用 `./gpu-node.sh migrate-iam --name <节点名>` 热切换到共用 Profile，不需要重启。原来那个 Role 能访问的 bucket 会自动合并进共用 Role。

## 运维跳板机

```bash
SSH_ALLOWED_CIDRS="203.0.113.10/32" ./deploy-bastion.sh
```

- **位置**：public subnet A，绑定 EIP（IP 固定，方便客户加进防火墙白名单）。机型 `t3.small`，系统 Amazon Linux 2023。
- **登录方式**：
  - **SSH**：来源限定为 `SSH_ALLOWED_CIDRS`（最多 5 个），用户名 `ec2-user`。
  - **SSM**：`aws ssm start-session --target <跳板机ID>`，不需要 key，也不需要开放端口。
- **SSH Key**：`KEY_NAME` 留空时，自动创建 `<project>-ops`（ed25519），私钥保存到 `~/.ssh/<project>-ops.pem`。在 CloudShell 中可以通过 **Actions → Download file** 下载到本机。也可以把 `KEY_NAME` 设为已有 key pair 的名称。
- **访问 GPU 实例**：跳板机可以访问 GPU 实例的 22 和 8000 端口。
  - **SSH**：跳板机创建**之后**再创建的 GPU 实例会自动挂载同一把 key。可以在本机用 `ssh -i <pem> -J ec2-user@<EIP> ec2-user@<GPU私网IP>` 一步登录。
  - **SSM**：在跳板机上执行 `aws ssm start-session --target <GPU实例ID>`，不依赖 key。
  - **已有的 GPU 实例**：之前创建、没有挂载 key 的实例只能走 SSM；如果需要 SSH，执行 `./launch-instance.sh --replace` 重建。
- **S3**：可以读写模型 bucket，以及 `OPS_EXTRA_BUCKETS` 中列出的 bucket（空格分隔）。
- **内置命令**：
  - `gpu-list`：列出本项目的 GPU 机器，包括 vLLM 实例（`Role=vllm`）和 `gpu-node.sh` 创建的机器（`Role=gpu-node`），以及它们的私网 IP。加 `--all` 可以查看本 Region 所有项目的机器。
  - `vllm-key`：输出 API Key，例如 `curl -H "Authorization: Bearer $(vllm-key)" http://<GPU私网IP>:8000/v1/models`。
  - 环境变量 `$MODEL_BUCKET` 已预先设置好。
- **机型**：`BASTION_INSTANCE_TYPE` 留空时会弹出菜单，分 x86_64 和 arm64 两组列出推荐机型，并附上实时按需价格和适用场景。默认 `t3.small`；ARM 推荐 `t4g.small`，同等规格大约便宜 20%。也可以手动输入其他机型。脚本会按架构自动选择 AL2023 AMI 和 session-manager-plugin。**更换机型或修改 user-data 会替换跳板机实例**：EIP 不变，但跳板机上的本地文件会丢失，SSH host key 也会变化。
- **跳板机按项目划分**：每个项目（`PROJECT_NAME`）有自己的跳板机，`gpu-list` 默认只列本项目的机器。只有和跳板机在同一个 VPC 的机器才能 SSH 登录；其他 VPC 的机器请用 SSM。在跳板机**之后**创建的 GPU 机器才会自动放行来自跳板机的 SSH。
- **修改配置**：修改 `SSH_ALLOWED_CIDRS` 或 `OPS_EXTRA_BUCKETS` 后，重新执行 `./deploy-bastion.sh` 即可。执行 `destroy.sh` 时会先删除跳板机栈。

## 裸 GPU 机器（OCR / Embedding 等自定义模型）

`gpu-node.sh` 只负责启动 GPU 机器，**不部署任何模型**，客户在机器上自行用 Docker 部署 OCR、Embedding 等服务。

```bash
./gpu-node.sh create --name ocr                       # 交互式: 机型 → DLAMI → 子网 (默认私有子网)
NODE_SERVICE_PORTS="8001 8002" ./gpu-node.sh create --name embedding --with-nlb   # 对外暴露端口
./gpu-node.sh list                                    # 列出所有节点
./gpu-node.sh delete --name ocr                       # 终止机器，并删除它的 IAM / SG / NLB
```

| 项目 | 说明 |
|---|---|
| 子网选择 | 列出账号里的所有子网，本项目 VPC 排在最前。根据路由表自动判断公有 / 私有，并标出每个 AZ 是否有所选机型。**默认选第一个"私有 + 机型可用"的子网**。也可以用 `NODE_SUBNET_ID` 直接指定 |
| 容量回退 | 所选子网没有容量时，自动尝试同 VPC 其他 AZ 的同类型子网（`NODE_SUBNET_FALLBACK=0` 可关闭） |
| IAM Role | **与 vLLM 实例共用**推理栈的 `<project>-gpu-instance-<region>` Role / Instance Profile（见下方"共用 GPU IAM Role"）。因此需要先执行 `./deploy.sh` 或 `./deploy.sh --no-instance`；也可以用 `./deploy.sh --no-model` 一步完成建栈 + 创建裸 GPU 机器 |
| 安全组 | `NODE_SERVICE_PORTS`（最多 5 个）只对 VPC 内网开放；同 VPC 内有跳板机时放行 SSH；出站不限制 |
| NLB（可选） | 加 `--with-nlb` 时，为该机器单独创建一个 internet-facing NLB，每个端口一个 TCP listener，健康检查用 TCP（服务开始监听后才会变为 healthy），来源限定为 `NODE_ALLOWED_CIDRS`。**流量是 TCP 明文透传，鉴权需要由服务自己实现** |
| 初始化 | 实例存储 NVMe 组 RAID0，挂载到 `/mnt/nvme`；Docker 数据目录迁到 `/mnt/nvme/docker`（`NODE_DOCKER_ON_NVME=0` 可关闭）；挂载运维 SSH key。每次开机都会在 Docker 启动之前执行 |
| IMDS | hop limit 默认是 2，容器内可以用实例角色访问 S3 / ECR。如果容器不需要访问 AWS，建议设 `NODE_IMDS_HOP_LIMIT=1` |

> ⚠️ stop/start 之后实例存储会被清空，NVMe 会自动重建，但 `/mnt/nvme` 上的数据和 Docker 镜像都需要重新准备。需要持久保存的数据请放到 S3。

## GPU 容量获取建议

GPU 不是每个 AZ 都有供应，而且经常出现 `InsufficientInstanceCapacity`。脚本的处理方式如下：

1. `list-gpu.sh` 列出每个机型在哪些 AZ 有供应，括号里的数字是 **容量参考分**（基于 Spot Placement Score，1–10，只能作为参考，不代表 On-Demand 一定有货）。
2. 创建网络时，优先选择所选机型有供应的 AZ。
3. 创建实例时，按参考分从高到低依次尝试各 AZ，然后尝试 `FALLBACK_INSTANCE_TYPES`，一共重试 `CAPACITY_RETRY_ROUNDS` 轮。
4. 如果仍然拿不到容量，可以购买 **On-Demand Capacity Reservation** 或 **EC2 Capacity Blocks for ML**，再设置 `CAPACITY_RESERVATION_ID`。

## 安全设计

- GPU 实例放在 private subnet，没有公网 IP。SSH 只允许来自跳板机 SG，也可以通过 SSM 访问。
- 跳板机的 SSH 只放行 `SSH_ALLOWED_CIDRS`，并强制 IMDSv2。IAM 权限只包含：项目内 bucket 的读写、本项目 API Key 的读取、vLLM 日志的读取，以及对带本项目 Tag 的实例发起 SSM 会话。
- 实例 SG 只放行来自 NLB SG 的 8000 端口；NLB SG 只放行 `ALLOWED_CIDRS`。
- vLLM 的 `/v1/*` 接口需要 `Authorization: Bearer <API_KEY>`。API Key 由 Secrets Manager 生成，在实例上只写入 tmpfs（`/run/llm`），不会出现在 user-data 或进程参数中。
- 强制使用 IMDSv2，hop limit = 1，容器内无法获取实例凭证。
- IAM 只授予所需的最小权限：只能读写 bucket 中 `models/` 前缀下的对象、只能读取本项目的 secret、只能写本项目的 log group。
- S3 开启 Block Public Access、SSE-S3 和 Versioning（旧版本 30 天后过期），并且只允许 TLS 访问；EBS 加密。
- 从 HF 只下载 safetensors / 配置 / tokenizer 文件，不下载 pickle 格式的权重。生产环境建议把 `MODEL_REVISION` 固定为 commit SHA，把 `VLLM_IMAGE` 固定为 digest 或镜像到 ECR。
- ⚠️ vLLM 的 API Key 只保护 `/v1/*`。`/health`、`/metrics`、`/tokenize` 等路由不需要鉴权，目前依靠 `ALLOWED_CIDRS` 白名单限制访问。
- ⚠️ vLLM 默认的 CORS 是 `allowed-origins=["*"]`。因为鉴权用的是 Bearer token（不是 cookie），风险较低；如果有浏览器端直接调用的场景，建议在 `VLLM_EXTRA_ARGS` 中限制 `--allowed-origins`。
- ⚠️ NLB 使用的是 **TCP 明文**。生产环境建议在 NLB 上加 TLS listener（ACM 证书），或者改成 internal NLB + VPN / Direct Connect。

## 费用提示（按需价格，以官网为准）

主要费用来自 GPU 实例（g6.12xlarge）、NAT Gateway（按小时 + 数据处理量）、NLB（按小时 + LCU），以及 S3 存储（约 35GB）。不用的时候执行 `./destroy.sh`，或者在控制台 stop 实例（stop 之后实例存储会清空，下次启动会从 S3 自动恢复权重）。

## 故障排查

| 现象 | 排查 |
|---|---|
| Target 一直 `unhealthy` / `initial` | 首次启动需要拉镜像 + 下载权重，先看 `journalctl -u vllm -f` |
| `Hugging Face 下载失败` | 检查 NAT 出网；gated 模型需要配置 `HF_TOKEN_SECRET_ARN` |
| `docker pull` 失败 / 被限流 | 把镜像推到 ECR，并设置 `VLLM_IMAGE` |
| vLLM 报 OOM | 降低 `VLLM_MAX_MODEL_LEN`，或加 `--language-model-only`，或换更大机型 |
| 所有 AZ 容量不足 | 见上文"GPU 容量获取建议" |
| 删除栈后重新部署报 IAM / Secret 名称冲突 | 确认 `./destroy.sh` 已执行完成 |
