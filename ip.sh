#!/bin/bash
# ================================================
# Trojan-Go 多IP限制 + Fail2ban 管理脚本
# ================================================

CONF_FILE="/etc/trojan-ban.conf"
CHECK_SCRIPT="/usr/local/bin/check_trojan_users.sh"
BAN_LOG="/var/log/trojan-ban.log"
CRON_JOB="*/5 * * * * $CHECK_SCRIPT"

# ================= 配置文件 =================
init_config() {
    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<EOF
# Trojan-Go 日志路径
LOG_FILE="/etc/trojan-go/log.txt"
# 每个用户允许的最大IP数
MAX_IPS=2
# 检查最近多少分钟的日志
TIME_RANGE=5
# 封禁时长(秒)
BAN_TIME=600
EOF
    fi
    source "$CONF_FILE"
}

# ================= 脚本生成 =================
gen_check_script() {
    cat > "$CHECK_SCRIPT" <<EOF
#!/bin/bash
source $CONF_FILE
TMP_FILE="/tmp/trojan_ips.txt"
since=\$(date +"%Y/%m/%d %H:%M" --date="-\$TIME_RANGE min")

grep "\$since" "\$LOG_FILE" \\
    | grep "user " \\
    | awk '{for(i=1;i<=NF;i++){if(\$i=="user"){user=\$(i+1)}; if(\$i=="from"){split(\$(i+1),a,":"); ip=a[1]}}; if(user!=""&&ip!="") print user,ip}' \\
    | sort -u > "\$TMP_FILE"

cut -d' ' -f1 "\$TMP_FILE" | sort -u | while read user; do
    ips=\$(grep "^\$user " "\$TMP_FILE" | awk '{print \$2}' | sort -u)
    count=\$(echo "\$ips" | wc -l)
    if [ "\$count" -gt "\$MAX_IPS" ]; then
        echo "[\$(date '+%F %T')] 用户 \$user 超出限制 (IP数=\$count)" >> "$BAN_LOG"
        extra_ips=\$(echo "\$ips" | tail -n +\$((MAX_IPS+1)))
        for bad_ip in \$extra_ips; do
            echo "[\$(date '+%F %T')] → 封禁 \$bad_ip via Fail2ban (user=\$user)" >> "$BAN_LOG"
            fail2ban-client set trojan-go banip "\$bad_ip"
        done
    fi
done
EOF
    chmod +x "$CHECK_SCRIPT"
}

# ================= Fail2ban 配置 =================
setup_fail2ban() {
    # filter
    cat > /etc/fail2ban/filter.d/trojan-go.conf <<EOF
[Definition]
failregex = ^.*user .* from <HOST>:.*\$
ignoreregex =
EOF

    # jail
    cat > /etc/fail2ban/jail.local <<EOF
[trojan-go]
enabled  = true
filter   = trojan-go
logpath  = $LOG_FILE
maxretry = 1
findtime = 600
bantime  = $BAN_TIME
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
}

# ================= 功能 =================
start_service() {
    init_config
    gen_check_script
    setup_fail2ban
    # 加入定时任务
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | sort -u | crontab -
    echo ">>> 服务已启动（每5分钟检测一次）"
}

stop_service() {
    crontab -l | grep -v "$CHECK_SCRIPT" | crontab -
    systemctl stop fail2ban
    echo ">>> 服务已关闭"
}

unban_all() {
    jails=$(fail2ban-client status | grep "Jail list" | cut -d: -f2)
    for jail in $jails; do
        banned=$(fail2ban-client status $jail | grep "Banned IP list:" | cut -d: -f2)
        for ip in $banned; do
            fail2ban-client set $jail unbanip $ip
        done
    done
    echo ">>> 所有封禁已解除"
}

show_banned() {
    if [ -f "$BAN_LOG" ]; then
        echo "=== 被封用户记录 ==="
        cat "$BAN_LOG"
    else
        echo "暂无封禁记录"
    fi
}

# ================= 菜单 =================
menu() {
    clear
    echo "================================"
    echo " Trojan-Go 多IP限制 管理脚本"
    echo " 配置文件: $CONF_FILE"
    echo " 检测脚本: $CHECK_SCRIPT"
    echo " 封禁日志: $BAN_LOG"
    echo "================================"
    echo "1. 开启服务"
    echo "2. 关闭服务"
    echo "3. 解锁所有封禁"
    echo "4. 显示被封用户"
    echo "0. 退出"
    echo "================================"
    read -p "请输入选择: " num
    case $num in
        1) start_service ;;
        2) stop_service ;;
        3) unban_all ;;
        4) show_banned ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

# ================= 主程序 =================
menu
