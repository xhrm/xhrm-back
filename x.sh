#!/bin/bash

# 定义要屏蔽的域名列表
BLOCKED_DOMAINS=(
    "chatgpt.com"
    "openai.com"
)

# 备份原始的 /etc/hosts 文件
HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.bak"
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

# 刷新网络服务（某些系统需要）
if command -v systemctl &>/dev/null; then
    systemctl restart nscd || systemctl restart network
else
    echo "系统未使用 systemd，手动刷新网络服务（如有需要）。"
fi

echo "屏蔽完成。"
