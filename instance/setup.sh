# user-data 尾部 (由 launch-instance.sh 拼接): 安装 systemd unit 并启动
command -v docker >/dev/null 2>&1 || { echo "Docker 未安装，请使用 Deep Learning AMI"; exit 1; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "NVIDIA Driver 未安装，请使用 Deep Learning AMI"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "AWS CLI 未安装"; exit 1; }
systemctl enable --now docker

cat >/etc/systemd/system/vllm.service <<'__UNIT__'
[Unit]
Description=vLLM OpenAI-compatible inference server (Docker)
After=network-online.target docker.service dlami-nvme.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/opt/llm/prepare.sh
ExecStart=/opt/llm/run-vllm.sh
ExecStop=/usr/bin/docker stop -t 30 vllm
Restart=always
RestartSec=30
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
__UNIT__

systemctl daemon-reload
systemctl enable vllm.service
systemctl start --no-block vllm.service
echo "vllm.service 已启动，查看进度: journalctl -u vllm -f"
