#!/bin/bash
# ================================================
# Trojan-Go 多IP限制 + Fail2ban 管理脚本 (最终优化版)
# 支持: CentOS 7 / Ubuntu / Debian
# ================================================

set -euo pipefail

CONF_FILE="/etc/trojan-ban.conf"
CHECK_SCRIPT="/usr/local/bin/check_trojan_users.sh"
BAN_LOG="/var/log/trojan-ban.log"
CRON_JOB="*/5 * * * * $CHECK_SCRIPT"

# ================= 系统检测 =================
detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="centos"
        OS_VER=$(rpm -E %{rhel})
        if [ "$OS_VER" != "7" ]; then
            echo ">>> 仅支持 CentOS 7"
            exit 1
        fi
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VER=$(lsb_release -sr 2>/dev/null || cat /etc/debian_version)
    else
        echo "不支持的系统"
        exit 1
    fi
    echo ">>> 检测到系统: $OS_TYPE $OS_VER"
}

# ================= 安装 Fail2ban =================
install_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        echo ">>> Fail2ban 已安装"
        return
    fi

    echo ">>> 安装 Fail2ban ..."
    if [ "$OS_TYPE" == "centos" ]; then
        yum install -y epel-release
        yum install -y fail2ban
    else
        apt update
        apt install -y fail2ban
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban
}

# ================= 初始化配置 =================
init_config() {
    # 默认值
    LOG_FILE="/etc/trojan-go/log.txt"
    MAX_IPS=3
    TIME_RANGE=5
    BAN_TIME=1800
    BAN_MODE="extra"   # "extra"=封禁超出的IP, "all"=封禁所有IP

    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<EOF
# Trojan-Go 日志路径
LOG_FILE="$LOG_FILE"
# 每个用户允许的最大IP数
MAX_IPS=$MAX_IPS
# 检查最近多少分钟的日志
TIME_RANGE=$TIME_RANGE
# 封禁时长(秒)
BAN_TIME=$BAN_TIME
# 封禁模式: extra=只封禁超出的IP, all=封禁所有IP
BAN_MODE="$BAN_MODE"
EOF
        echo ">>> 已生成默认配置文件: $CONF_FILE"
    fi
    # shellcheck disable=SC1090
    source "$CONF_FILE"
}

# ================= 生成检测脚本 =================
gen_check_script() {
    cat > "$CHECK_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail
source /etc/trojan-ban.conf
TMP_FILE=$(mktemp /tmp/trojan_ips.XXXXXX)

since=$(date -d "-$TIME_RANGE minutes" +%s)

awk -v since="$since" '
{
    # 假设日志格式: 2025-10-05 17:22:33 [INFO] user xxx from 1.2.3.4:port
    ts=$1" "$2
    gsub(/[-:]/," ",ts)
    split(ts,t," ")
    logtime=mktime(t[1]" "t[2]" "t[3]" "t[4]" "t[5]" "t[6])
    if (logtime >= since && /user .* from/) {
        for (i=1;i<=NF;i++) {
            if ($i=="user") user=$(i+1)
            if ($i=="from") { split($(i+1),a,":"); ip=a[1] }
        }
        if (user!="" && ip!="") print user, ip
    }
}' "$LOG_FILE" | sort -u > "$TMP_FILE"

while read -r user; do
    ips=$(grep "^$user " "$TMP_FILE" | awk '{print $2}' | sort -u)
    count=$(echo "$ips" | wc -l)
    if [ "$count" -gt "$MAX_IPS" ]; then
        if [ "$BAN_MODE" = "all" ]; then
            echo "[$(date '+%F %T')] 用户 $user 超出限制 (IP数=$count)，封禁其所有IP" >> "/var/log/trojan-ban.log"
            for bad_ip in $ips; do
                echo "[$(date '+%F %T')] → 封禁 $bad_ip via Fail2ban (user=$user)" >> "/var/log/trojan-ban.log"
                fail2ban-client set trojan-go banip "$bad_ip"
            done
        else
            echo "[$(date '+%F %T')] 用户 $user 超出限制 (IP数=$count)，封禁超出的IP" >> "/var/log/trojan-ban.log"
            extra_ips=$(echo "$ips" | tail -n +$((MAX_IPS+1)))
            for bad_ip in $extra_ips; do
                echo "[$(date '+%F %T')] → 封禁 $bad_ip via Fail2ban (user=$user)" >> "/var/log/trojan-ban.log"
                fail2ban-client set trojan-go banip "$bad_ip"
            done
        fi
    fi
done < <(cut -d' ' -f1 "$TMP_FILE" | sort -u)

rm -f "$TMP_FILE"
EOF
    chmod +x "$CHECK_SCRIPT"
    echo ">>> 已生成检测脚本: $CHECK_SCRIPT"
}

# ================= Fail2ban 配置 =================
setup_fail2ban() {
    mkdir -p /etc/fail2ban/filter.d/

    # filter
    cat > /etc/fail2ban/filter.d/trojan-go.conf <<EOF
[Definition]
failregex = ^.*user .* from <HOST>:.*\$
ignoreregex =
EOF

    # jail（只追加，不覆盖）
    if ! grep -q "\[trojan-go\]" /etc/fail2ban/jail.local 2>/dev/null; then
        cat >> /etc/fail2ban/jail.local <<EOF

[trojan-go]
enabled  = true
filter   = trojan-go
logpath  = $LOG_FILE
maxretry = 1
findtime = 600
bantime  = $BAN_TIME
EOF
    fi

    systemctl restart fail2ban
    echo ">>> Fail2ban 配置完成并已启动"
}

# ================= 功能 =================
start_service() {
    init_config
    install_fail2ban
    gen_check_script
    setup_fail2ban
    (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT"; echo "$CRON_JOB") | sort -u | crontab -
    echo ">>> 服务已启动（每5分钟检测一次）"
}

stop_service() {
    crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT" | crontab - || true
    systemctl stop fail2ban || true
    echo ">>> 服务已关闭"
}

unban_all() {
    jails=$(fail2ban-client status | grep "Jail list" | cut -d: -f2)
    for jail in $jails; do
        banned=$(fail2ban-client status "$jail" | grep "Banned IP list:" | cut -d: -f2)
        for ip in $banned; do
            fail2ban-client set "$jail" unbanip "$ip"
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

change_max_ips() {
    read -p "请输入新的最大IP数量: " new_ips
    if [[ ! "$new_ips" =~ ^[0-9]+$ ]] || [ "$new_ips" -lt 1 ]; then
        echo "无效的数字"
        return
    fi
    sed -i "s/^MAX_IPS=.*/MAX_IPS=$new_ips/" "$CONF_FILE"
    echo ">>> 已修改 MAX_IPS=$new_ips"
    source "$CONF_FILE"
    "$CHECK_SCRIPT"
    echo ">>> 设置已应用并立即生效"
}

change_ban_time() {
    read -p "请输入新的封禁时长(秒): " new_ban
    if [[ ! "$new_ban" =~ ^[0-9]+$ ]] || [ "$new_ban" -lt 60 ]; then
        echo "无效的封禁时长（必须 ≥60 秒）"
        return
    fi
    sed -i "s/^BAN_TIME=.*/BAN_TIME=$new_ban/" "$CONF_FILE"
    echo ">>> 已修改 BAN_TIME=$new_ban"
    source "$CONF_FILE"
    sed -i "s/^\(bantime\s*=\s*\).*/\1$BAN_TIME/" /etc/fail2ban/jail.local
    systemctl restart fail2ban
    echo ">>> 封禁时长已更新并立即生效"
}

change_ban_mode() {
    echo "当前模式: $BAN_MODE"
    echo "1. extra (只封禁超出的IP)"
    echo "2. all   (封禁所有IP)"
    read -p "请选择新的模式 [1/2]: " mode
    case $mode in
        1) new_mode="extra" ;;
        2) new_mode="all" ;;
        *) echo "无效选择"; return ;;
    esac
    sed -i "s/^BAN_MODE=.*/BAN_MODE=\"$new_mode\"/" "$CONF_FILE"
    echo ">>> 已修改 BAN_MODE=$new_mode"
    source "$CONF_FILE"
    echo ">>> 模式已切换"
}

# ================= 菜单 =================
menu() {
    while true; do
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
        echo "5. 修改最大允许IP数 (当前: $MAX_IPS)"
        echo "6. 修改封禁时长 (当前: $BAN_TIME 秒)"
        echo "7. 切换封禁模式 (当前: $BAN_MODE)"
        echo "0. 退出"
        echo "================================"
        read -p "请输入选择: " num
        case $num in
            1) start_service ;;
            2) stop_service ;;
            3) unban_all ;;
            4) show_banned ;;
            5) change_max_ips ;;
            6) change_ban_time ;;
            7) change_ban_mode ;;
            0) exit 0 ;;
            *) echo "无效选择"; sleep 2 ;;
        esac
        read -p "按回车返回菜单..."
        source "$CONF_FILE"
    done
}

# ================= 主程序 =================
detect_os
init_config
menu
