#!/bin/bash

# =================================================
# 仅屏蔽 AI 服务（ChatGPT / Gemini）
# hosts + ipset + nftables / iptables（真实可用才用）
# =================================================

BLOCKED_DOMAINS=(
    "chatgpt.com"
    "auth.openai.com"
    "api.openai.com"
    "platform.openai.com"
    "gemini.google.com"
    "generativelanguage.googleapis.com"
)

HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.bak"
IPSET_NAME="ai_block"

# -------- root 校验 --------
if [ "$EUID" -ne 0 ]; then
    echo "必须使用 root 权限运行"
    exit 1
fi

# -------- hosts 备份 --------
if [ ! -f "$BACKUP_FILE" ]; then
    cp "$HOSTS_FILE" "$BACKUP_FILE"
fi

# -------- hosts 层 --------
for DOMAIN in "${BLOCKED_DOMAINS[@]}"; do
    grep -q "$DOMAIN" "$HOSTS_FILE" || {
        echo "127.0.0.1 $DOMAIN" >> "$HOSTS_FILE"
        echo "127.0.0.1 www.$DOMAIN" >> "$HOSTS_FILE"
    }
done

# -------- ipset --------
IPSET_OK=0
if command -v ipset &>/dev/null; then
    ipset list "$IPSET_NAME" &>/dev/null || ipset create "$IPSET_NAME" hash:ip

    for DOMAIN in "${BLOCKED_DOMAINS[@]}"; do
        getent ahosts "$DOMAIN" | awk '{print $1}' | sort -u | while read -r ip; do
            ipset add "$IPSET_NAME" "$ip" 2>/dev/null
        done
    done
    IPSET_OK=1
fi

# -------- 防火墙层 --------
FW_OK=0

if [ "$IPSET_OK" -eq 1 ] && command -v nft &>/dev/null; then
    nft list table inet filter &>/dev/null || nft add table inet filter
    nft list chain inet filter output &>/dev/null || \
        nft add chain inet filter output '{ type filter hook output priority 0; }'

    nft list chain inet filter output | grep -q "@$IPSET_NAME" || \
        nft add rule inet filter output ip daddr @"$IPSET_NAME" drop

    FW_OK=1

elif [ "$IPSET_OK" -eq 1 ] && command -v iptables &>/dev/null; then
    iptables -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null || \
        iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP

    FW_OK=1
fi

# -------- 最终状态输出 --------
echo "======== 屏蔽状态 ========"

echo "hosts     : 已生效"

if [ "$IPSET_OK" -eq 1 ]; then
    echo "ipset     : 已生效"
else
    echo "ipset     : 未启用"
fi

if [ "$FW_OK" -eq 1 ]; then
    echo "防火墙层 : 已生效（内核级拦截）"
else
    echo "防火墙层 : 未启用（仅 hosts 层）"
fi

echo "=========================="
