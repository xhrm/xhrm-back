#!/bin/bash

# ==========================================
# 仅屏蔽 AI 服务（ChatGPT / Gemini）
# hosts + ipset + nftables
# 不影响其它 Google / 网络服务
# ==========================================

# -------- 精确 AI 域名列表 --------
BLOCKED_DOMAINS=(
    # OpenAI / ChatGPT
    "chatgpt.com"
    "auth.openai.com"
    "api.openai.com"
    "platform.openai.com"

    # Google Gemini
    "gemini.google.com"
    "generativelanguage.googleapis.com"
)

# -------- 文件与对象定义 --------
HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.bak"

IPSET_NAME="ai_block"
NFT_TABLE="inet filter"
NFT_CHAIN="output"

# -------- root 校验 --------
if [ "$EUID" -ne 0 ]; then
    echo "必须使用 root 权限运行"
    exit 1
fi

# -------- 备份 hosts --------
if [ ! -f "$BACKUP_FILE" ]; then
    cp "$HOSTS_FILE" "$BACKUP_FILE"
fi

# -------- hosts 层屏蔽 --------
for DOMAIN in "${BLOCKED_DOMAINS[@]}"; do
    if ! grep -q "$DOMAIN" "$HOSTS_FILE"; then
        echo "127.0.0.1 $DOMAIN" >> "$HOSTS_FILE"
        echo "127.0.0.1 www.$DOMAIN" >> "$HOSTS_FILE"
    fi
done

# -------- ipset 初始化 --------
if ! command -v ipset &>/dev/null; then
    echo "未安装 ipset"
    exit 1
fi

if ! ipset list "$IPSET_NAME" &>/dev/null; then
    ipset create "$IPSET_NAME" hash:ip
fi

# -------- 解析 AI 域名并加入 ipset --------
for DOMAIN in "${BLOCKED_DOMAINS[@]}"; do
    getent ahosts "$DOMAIN" | awk '{print $1}' | sort -u | while read -r ip; do
        ipset add "$IPSET_NAME" "$ip" 2>/dev/null
    done
done

# -------- nftables 初始化 --------
if ! command -v nft &>/dev/null; then
    echo "未安装 nftables"
    exit 1
fi

if ! nft list table inet filter &>/dev/null; then
    nft add table inet filter
fi

if ! nft list chain inet filter output &>/dev/null; then
    nft add chain inet filter output '{ type filter hook output priority 0; }'
fi

# -------- nftables 屏蔽规则 --------
if ! nft list chain inet filter output | grep -q "@$IPSET_NAME"; then
    nft add rule inet filter output ip daddr @"$IPSET_NAME" drop
fi

# -------- DNS 缓存刷新（保持最小） --------
if command -v systemctl &>/dev/null; then
    if systemctl is-active systemd-resolved &>/dev/null; then
        systemctl restart systemd-resolved
    elif systemctl is-active NetworkManager &>/dev/null; then
        systemctl restart NetworkManager
    fi
fi

echo "完成：仅 AI 服务（ChatGPT / Gemini）已被屏蔽"
