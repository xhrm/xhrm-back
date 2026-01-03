#!/bin/bash

# ==========================================
# AI 服务自动屏蔽脚本
# 默认执行：立即屏蔽 + 开机自动生效
# 恢复：ai-block.sh restore
# ==========================================

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

SELF_PATH="$(readlink -f "$0")"
SERVICE_NAME="ai-block.service"

# ---------- root ----------
[ "$EUID" -ne 0 ] && { echo "必须使用 root 权限运行"; exit 1; }

# ---------- hosts ----------
backup_hosts() {
    [ -f "$BACKUP_FILE" ] || cp "$HOSTS_FILE" "$BACKUP_FILE"
}

add_hosts() {
    for d in "${BLOCKED_DOMAINS[@]}"; do
        grep -q "$d" "$HOSTS_FILE" || {
            echo "127.0.0.1 $d" >> "$HOSTS_FILE"
            echo "127.0.0.1 www.$d" >> "$HOSTS_FILE"
        }
    done
}

restore_hosts() {
    [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$HOSTS_FILE"
}

# ---------- ipset ----------
setup_ipset() {
    command -v ipset &>/dev/null || return 1
    ipset list "$IPSET_NAME" &>/dev/null || ipset create "$IPSET_NAME" hash:ip
    for d in "${BLOCKED_DOMAINS[@]}"; do
        getent ahosts "$d" | awk '{print $1}' | sort -u | while read -r ip; do
            ipset add "$IPSET_NAME" "$ip" 2>/dev/null
        done
    done
    return 0
}

cleanup_ipset() {
    command -v ipset &>/dev/null && ipset destroy "$IPSET_NAME" 2>/dev/null
}

# ---------- firewall ----------
setup_fw() {
    if command -v nft &>/dev/null; then
        nft list table inet filter &>/dev/null || nft add table inet filter
        nft list chain inet filter output &>/dev/null || \
            nft add chain inet filter output '{ type filter hook output priority 0; }'
        nft list chain inet filter output | grep -q "@$IPSET_NAME" || \
            nft add rule inet filter output ip daddr @"$IPSET_NAME" drop
        return 0
    fi

    if command -v iptables &>/dev/null; then
        iptables -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null || \
            iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP
        return 0
    fi
    return 1
}

cleanup_fw() {
    command -v nft &>/dev/null && nft flush chain inet filter output 2>/dev/null
    command -v iptables &>/dev/null && \
        iptables -D OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null
}

# ---------- autostart ----------
enable_autostart() {
    if command -v systemctl &>/dev/null; then
        cat >/etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=AI Block (ChatGPT / Gemini)
After=network.target

[Service]
Type=oneshot
ExecStart=$SELF_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable $SERVICE_NAME
        return
    fi

    # fallback cron
    (crontab -l 2>/dev/null | grep -v "$SELF_PATH"; \
     echo "@reboot $SELF_PATH") | crontab -
}

disable_autostart() {
    if command -v systemctl &>/dev/null; then
        systemctl disable $SERVICE_NAME 2>/dev/null
        rm -f /etc/systemd/system/$SERVICE_NAME
        systemctl daemon-reload
    fi
    crontab -l 2>/dev/null | grep -v "$SELF_PATH" | crontab - 2>/dev/null
}

# ---------- restore ----------
if [ "$1" = "restore" ]; then
    restore_hosts
    cleanup_fw
    cleanup_ipset
    disable_autostart
    echo "✔ 已恢复，并取消开机自动生效"
    exit 0
fi

# ---------- default: block ----------
backup_hosts
add_hosts

if setup_ipset && setup_fw; then
    echo "✔ AI 服务已屏蔽（含防火墙层）"
else
    echo "⚠ 仅 hosts 层生效"
fi

enable_autostart
echo "✔ 已设置开机 / 重启自动生效"
