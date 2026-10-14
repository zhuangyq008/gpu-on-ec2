# GPU-on-EC2：在 AWS 马来西亚区域用 vLLM 部署 LLM 推理服务

一套 Bash + CloudFormation 脚本，在 **ap-southeast-5（马来西亚）** 自动完成以下工作：

- 创建 VPC，划分 public / private subnet（2 个 AZ）
- 列出 Region 内可用的 GPU 机型和 AZ，默认 **g6 全家族**，默认机型 **g6.12xlarge**
- 列出 Deep Learning AMI，交互式选择
- 跨 AZ（以及可选的备选机型）自动重试，抢占 GPU 容量
- 模型权重：首次从 Hugging Face 下载并存入 **S3**，之后每次启动都从 S3 拉到 **NVMe 实例存储**（RAID0）
- 用 **Docker 运行 vLLM**（OpenAI 兼容 API），默认模型 `Qwen/Qwen3.5-35B-A3B-FP8`
- 通过 **internet-facing NLB** 对外提供服务，鉴权方式为 API Key + 来源 CIDR 白名单

## 架构

```
                        Internet (仅 ALLOWED_CIDRS)
                                  │ TCP :8000
┌──────────────────────── VPC 10.50.0.0/16 ───────────────────────────────┐
│  ┌─ Public Subnet A ─────────┐      ┌─ Public Subnet B ─────────┐       │
│  │  NLB (SG: allowed CIDRs)  │      │  NLB (cross-zone)         │       │
│  │  NAT Gateway              │      │  [NAT Gateway] (per-az)   │       │
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
├── destroy.sh            # 销毁全部资源 (S3 bucket 保留)
├── cfn/
│   ├── network.yaml      # VPC / Subnets / IGW / NAT / S3 Endpoint
│   └── inference.yaml    # NLB / SG / IAM / Secret / S3 / Logs
├── instance/             # 通过 user-data 下发到 EC2
│   ├── prepare.sh        # NVMe RAID0 + 权重准备
│   ├── run-vllm.sh       # docker run vLLM
│   └── setup.sh          # 安装 systemd unit
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

# 3. 部署 (交互式选择机型和 AMI)
./deploy.sh

# 4. 查看状态 + 冒烟测试
./status.sh --test
```

非交互部署（CI / 批量）：

```bash
ALLOWED_CIDRS="203.0.113.10/32" ./deploy.sh --yes
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
| 登录实例 | `aws ssm start-session --target <instance-id>`（没有 SSH，不需要 key pair） |
| 查看启动进度 | 实例上执行 `sudo journalctl -u vllm -f` |
| vLLM 日志 | CloudWatch Logs `/<project>/vllm`，或在实例上执行 `docker logs -f vllm` |
| 重启服务 | `sudo systemctl restart vllm` |
| 轮换 API Key | 在 Secrets Manager 中更新 secret → `sudo systemctl restart vllm` |
| 销毁 | `./destroy.sh`（S3 权重保留，下次部署自动复用） |

## GPU 容量获取建议

GPU 不是每个 AZ 都有供应，而且经常出现 `InsufficientInstanceCapacity`。脚本的处理方式如下：

1. `list-gpu.sh` 列出每个机型在哪些 AZ 有供应，括号里的数字是 **容量参考分**（基于 Spot Placement Score，1–10，只能作为参考，不代表 On-Demand 一定有货）。
2. 创建网络时，优先选择所选机型有供应的 AZ。
3. 创建实例时，按参考分从高到低依次尝试各 AZ，然后尝试 `FALLBACK_INSTANCE_TYPES`，一共重试 `CAPACITY_RETRY_ROUNDS` 轮。
4. 如果仍然拿不到容量，可以购买 **On-Demand Capacity Reservation** 或 **EC2 Capacity Blocks for ML**，再设置 `CAPACITY_RESERVATION_ID`。

## 安全设计

- GPU 实例放在 private subnet，没有公网 IP、不开 SSH，运维通过 SSM 进行。
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
