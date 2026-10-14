#!/usr/bin/env bash
# 运维 SSH key pair: 自动创建 (私钥落地到 SSH_KEY_DIR) 或使用已有 key pair

key_pair_exists() {
  aws ec2 describe-key-pairs --key-names "$1" >/dev/null 2>&1
}

ops_key_path() { printf '%s/%s.pem' "$SSH_KEY_DIR" "$OPS_KEY_NAME"; }

# ensure_ops_key_pair: KEY_NAME 指定时只校验存在; 否则自动创建 <project>-ops
ensure_ops_key_pair() {
  local pem
  pem="$(ops_key_path)"
  if [[ -n "$KEY_NAME" ]]; then
    key_pair_exists "$KEY_NAME" || die "key pair '$KEY_NAME' 在 $AWS_REGION 不存在"
    ok "使用已有 key pair: $KEY_NAME (请自行保管对应私钥)"
    return
  fi
  if key_pair_exists "$OPS_KEY_NAME"; then
    if [[ -f "$pem" ]]; then
      ok "使用已有 key pair: $OPS_KEY_NAME (私钥 $pem)"
    else
      warn "key pair $OPS_KEY_NAME 已存在，但本机没有私钥 $pem"
      warn "如果私钥在其他机器上，请拷贝到该路径；否则删除该 key pair 后重跑以重新生成:"
      warn "  aws ec2 delete-key-pair --region $AWS_REGION --key-name $OPS_KEY_NAME"
      confirm "仍然继续 (跳板机将挂载该 key)?" || exit 1
    fi
    return
  fi
  install -d -m 700 "$SSH_KEY_DIR"
  [[ -e "$pem" ]] && die "$pem 已存在但 EC2 中没有对应 key pair，请先移走该文件"
  ( umask 077
    aws ec2 create-key-pair --key-name "$OPS_KEY_NAME" --key-type ed25519 --key-format pem \
      --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$PROJECT_NAME}]" \
      --query KeyMaterial --output text >"$pem" ) || { rm -f "$pem"; die "创建 key pair 失败"; }
  chmod 400 "$pem"
  ok "已创建 key pair $OPS_KEY_NAME，私钥保存到 $pem"
  if is_cloudshell; then
    warn "CloudShell 中请通过 Actions -> Download file 下载 $pem 到本机并妥善保管"
    warn "下载后建议从 CloudShell 删除私钥 (能登录该 CloudShell 的人都能读取): shred -u $pem"
  fi
  return 0
}

# GPU 实例创建时使用: key pair 存在则返回名称，否则为空 (GPU 实例仍可通过 SSM 访问)
gpu_key_name() {
  if key_pair_exists "$OPS_KEY_NAME"; then printf '%s' "$OPS_KEY_NAME"; fi
}
