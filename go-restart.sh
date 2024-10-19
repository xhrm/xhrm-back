#!/bin/bash

# 默认定时重启的时间（格式为HH:MM）
DEFAULT_RESTART_TIME="00:10"

# 提示用户输入定时重启的时间（格式为HH:MM）
read -p "请输入定时重启的时间 (格式为HH:MM，例如00:10)，按Enter键使用默认时间$DEFAULT_RESTART_TIME: " RESTART_TIME

# 如果用户没有输入时间，则使用默认时间
RESTART_TIME=${RESTART_TIME:-$DEFAULT_RESTART_TIME}

# 获取小时和分钟
HOUR=${RESTART_TIME%:*}
MINUTE=${RESTART_TIME#*:}

# 检查cron服务是否运行
if ! systemctl is-active --quiet crond; then
    echo "正在启动cron服务..."
    systemctl start crond
fi

# 添加定时重启任务到crontab
echo "$MINUTE $HOUR * * * /bin/systemctl restart trojan-go" | crontab -

echo "定时重启任务已设置，每天$HOUR:$MINUTE服务器将自动重启 trojan-go。"
