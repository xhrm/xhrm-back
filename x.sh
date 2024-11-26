#!/bin/bash

# 定义要屏蔽的域名列表
BLOCKED_DOMAINS=(
    "chatgpt.com"
    "openai.com"
)

# 定义 /etc/hosts 文件路径
HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.bak"

# 备份原始的 /etc/hosts 文件
if [ ! -f "$BACKUP_FILE" ]; then
    echo "备份 /etc/hosts 文件到 $BACKUP_FILE"
    cp $HOSTS_FILE $BACKUP_FILE
fi

# 添加屏蔽规则
echo "开始屏蔽域名..."
for DOMAIN in "${BLOCKED_DOMAINS[@]}"; do
    if ! grep -q "$DOMAIN" $HOSTS_FILE; then
        echo "127.0.0.1 $DOMAIN" >> $HOSTS_FILE
        echo "127.0.0.1 www.$DOMAIN" >> $HOSTS_FILE
        echo "已屏蔽: $DOMAIN"
    else
        echo "域名 $DOMAIN 已经屏蔽，跳过..."
    fi
done
 
# 检测并刷新 DNS 缓存
echo "尝试刷新 DNS 缓存..."
if command -v systemctl &>/dev/null; then
    if systemctl list-units --type=service | grep -q "nscd.service"; then
        echo "检测到 nscd 服务，正在重启..."
        systemctl restart nscd
    elif systemctl list-units --type=service | grep -q "NetworkManager.service"; then
        echo "检测到 NetworkManager 服务，正在重启..."
        systemctl restart NetworkManager
    elif systemctl list-units --type=service | grep -q "systemd-resolved.service"; then
        echo "检测到 systemd-resolved 服务，正在重启..."
        systemctl restart systemd-resolved
    else
        echo "未检测到支持的 DNS 缓存服务，跳过刷新。"
    fi
else
    echo "Systemctl 不可用，无法自动刷新网络服务，请手动刷新 DNS（如有需要）。"
fi

echo "屏蔽完成。"
