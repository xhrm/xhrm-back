#!/bin/bash
set -e

# 默认定时重启的时间（格式为HH:MM）
DEFAULT_RESTART_TIME="00:10"
SERVICE_NAME="trojan-go"
LOG_FILE="/etc/trojan-go/log.txt"

# 提示用户输入定时重启的时间（格式为HH:MM）
read -p "请输入定时重启的时间 (格式为HH:MM，例如00:10)，按Enter键使用默认时间 $DEFAULT_RESTART_TIME: " RESTART_TIME
RESTART_TIME=${RESTART_TIME:-$DEFAULT_RESTART_TIME}

# 校验输入格式
if [[ ! $RESTART_TIME =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "错误：时间格式无效，请使用 HH:MM，例如 00:10"
    exit 1
fi

# 获取小时和分钟
HOUR=${RESTART_TIME%:*}
MINUTE=${RESTART_TIME#*:}

# 检查 cron 服务是否运行（兼容 cron / crond）
if systemctl list-unit-files | grep -qE '^crond\.service'; then
    CRON_SERVICE="crond"
elif systemctl list-unit-files | grep -qE '^cron\.service'; then
    CRON_SERVICE="cron"
else
    echo "未找到 cron 服务，请确认已安装 cron。"
    exit 1
fi

if ! systemctl is-active --quiet "$CRON_SERVICE"; then
    echo "正在启动 $CRON_SERVICE 服务..."
    systemctl start "$CRON_SERVICE"
    systemctl enable "$CRON_SERVICE" >/dev/null 2>&1 || true
fi

# 构建任务命令（先清理日志，再重启）
CRON_JOB="$MINUTE $HOUR * * * rm -f $LOG_FILE && /bin/systemctl restart $SERVICE_NAME # auto_restart_$SERVICE_NAME"

# 读取现有 crontab 并更新（防止覆盖）
( crontab -l 2>/dev/null | grep -v "auto_restart_$SERVICE_NAME" ; echo "$CRON_JOB" ) | crontab -

echo "✅ 定时任务已设置：每天 $HOUR:$MINUTE 清理 $LOG_FILE 并自动重启 $SERVICE_NAME"
echo "当前任务列表："
crontab -l | grep "$SERVICE_NAME"
