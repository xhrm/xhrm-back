#!/bin/bash
# ============================================================
# Trojan-Go 智能限速 + Fail2ban 封禁管理 + systemd自启动
# 自动检测依赖、自动配置、自动自启
# ============================================================

set -euo pipefail

CONF_FILE="/etc/trojan_smart.conf"
CHECK_SCRIPT="/usr/local/bin/trojan_smart_check.sh"
SERVICE_FILE="/etc/systemd/system/trojan-manager.service"
LOG_FILE="/etc/trojan-go/log.txt"
BAN_LOG="/var/log/trojan-smart-ban.log"
JAIL_NAME="trojan-go"

PORT=443
LIMIT_UP_MBPS=20
LIMIT_DOWN_MBPS=20
MAX_IPS=3
CHECK_INTERVAL=10
BAN_TIME=1800
BAN_MODE="extra"

# ------------------------------------------------------------
init_config() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    else
        cat > "$CONF_FILE" <<EOF
PORT=$PORT
LIMIT_UP_MBPS=$LIMIT_UP_MBPS
LIMIT_DOWN_MBPS=$LIMIT_DOWN_MBPS
LOG_FILE="$LOG_FILE"
MAX_IPS=$MAX_IPS
CHECK_INTERVAL=$CHECK_INTERVAL
BAN_TIME=$BAN_TIME
BAN_MODE="$BAN_MODE"
EOF
        source "$CONF_FILE"
    fi
}

save_config() {
    cat > "$CONF_FILE" <<EOF
PORT=$PORT
LIMIT_UP_MBPS=$LIMIT_UP_MBPS
LIMIT_DOWN_MBPS=$LIMIT_DOWN_MBPS
LOG_FILE="$LOG_FILE"
MAX_IPS=$MAX_IPS
CHECK_INTERVAL=$CHECK_INTERVAL
BAN_TIME=$BAN_TIME
BAN_MODE="$BAN_MODE"
EOF
}

# ------------------------------------------------------------
check_dependencies() {
    echo "🔍 检查依赖..."
    for cmd in iptables fail2ban-client systemctl crontab awk grep; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "⚠️ 缺少 $cmd，正在尝试安装..."
            if command -v yum >/dev/null 2>&1; then
                yum install -y iptables fail2ban cronie || true
            elif command -v apt >/dev/null 2>&1; then
                apt update -y && apt install -y iptables fail2ban cron || true
            fi
        fi
    done
    echo "✅ 依赖检测完毕"
}

detect_iface() {
    ip route | awk '/default/ {print $5; exit}'
}

# ------------------------------------------------------------
# 限速模块
# ------------------------------------------------------------
apply_limits() {
    echo "⚙️ 应用限速: 每 IP 上下行 ${LIMIT_UP_MBPS}/${LIMIT_DOWN_MBPS} Mbps"
    clear_limits
    iptables -I INPUT  -p tcp --dport "$PORT" -m hashlimit \
        --hashlimit "${LIMIT_UP_MBPS}mb/s" --hashlimit-mode srcip --hashlimit-name trojan_up -j ACCEPT
    iptables -I OUTPUT -p tcp --sport "$PORT" -m hashlimit \
        --hashlimit "${LIMIT_DOWN_MBPS}mb/s" --hashlimit-mode srcip --hashlimit-name trojan_down -j ACCEPT
    echo "✅ 限速规则生效"
}

clear_limits() {
    echo "🧹 清理旧限速规则..."
    for chain in INPUT OUTPUT; do
        while iptables -S "$chain" 2>/dev/null | grep -q "hashlimit-name trojan_"; do
            rule=$(iptables -S "$chain" | grep "hashlimit-name trojan_" | head -n1)
            del_rule=$(echo "$rule" | sed 's/^-A /-D /')
            iptables $del_rule || true
        done
    done
    echo "✅ 清理完成"
}

# ------------------------------------------------------------
# Fail2ban 模块
# ------------------------------------------------------------
setup_fail2ban() {
    echo "⚙️ 配置 Fail2ban..."
    mkdir -p /etc/fail2ban/filter.d

    cat > /etc/fail2ban/filter.d/trojan-go.conf <<'EOF'
[Definition]
failregex = ^.*user .* from <HOST>:.*$
ignoreregex =
EOF

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

    systemctl enable fail2ban --now || true
    systemctl restart fail2ban || true
    echo "✅ Fail2ban 已配置"
}

generate_check_script() {
    cat > "$CHECK_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail
CONF="/etc/trojan_smart.conf"
source "$CONF"
TMP=$(mktemp)
since=$(date -d "-$CHECK_INTERVAL minutes" +%s)

awk -v since="$since" '
{
  ts=$1" "$2
  gsub(/[-:]/," ",ts)
  split(ts,t," ")
  logtime=mktime(t[1]" "t[2]" "t[3]" "t[4]" "t[5]" "t[6])
  if (logtime>=since && /user .* from/) {
    for (i=1;i<=NF;i++){
      if ($i=="user") user=$(i+1)
      if ($i=="from") {split($(i+1),a,":"); ip=a[1]}
    }
    if(user!="" && ip!="") print user,ip
  }
}' "$LOG_FILE" | sort -u > "$TMP"

while read -r user; do
  ips=$(grep "^$user " "$TMP" | awk '{print $2}' | sort -u)
  count=$(echo "$ips" | wc -l)
  if [ "$count" -gt "$MAX_IPS" ]; then
    if [ "$BAN_MODE" = "all" ]; then
      for ip in $ips; do
        fail2ban-client set trojan-go banip "$ip" || true
        echo "[$(date '+%F %T')] 封禁: $ip (user=$user, all)" >> "$BAN_LOG"
      done
    else
      extra=$(echo "$ips" | tail -n +$((MAX_IPS+1)))
      for ip in $extra; do
        fail2ban-client set trojan-go banip "$ip" || true
        echo "[$(date '+%F %T')] 封禁: $ip (user=$user, extra)" >> "$BAN_LOG"
      done
    fi
  fi
done < <(cut -d' ' -f1 "$TMP" | sort -u)
rm -f "$TMP"
EOF
    chmod +x "$CHECK_SCRIPT"
}

enable_banning() {
    setup_fail2ban
    generate_check_script
    (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT" || true; echo "*/$CHECK_INTERVAL * * * * $CHECK_SCRIPT") | crontab -
    echo "✅ 封禁检测启用（每 $CHECK_INTERVAL 分钟）"
}

disable_banning() {
    (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT" || true) | crontab -
    echo "✅ 封禁检测关闭"
}

show_banned() {
    echo "=== 当前被封 IP ==="
    fail2ban-client status "$JAIL_NAME" 2>/dev/null | awk -F: '/Banned IP list/ {print $2}'
    echo "-----------------------------------"
    [ -f "$BAN_LOG" ] && tail -n 30 "$BAN_LOG" || echo "无封禁记录"
}

unban_all() {
    banned=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null | awk -F: '/Banned IP list/ {print $2}')
    for ip in $banned; do
        fail2ban-client set "$JAIL_NAME" unbanip "$ip" || true
    done
    echo "✅ 已解封全部 IP"
}

# ------------------------------------------------------------
# systemd 自启动
# ------------------------------------------------------------
setup_systemd_service() {
    echo "⚙️ 创建 systemd 服务..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Trojan-Go 限速与封禁管理
After=network-online.target fail2ban.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/trojan_manager.sh --autostart
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable trojan-manager.service
    echo "✅ 已配置 systemd 自启服务"
}

# ------------------------------------------------------------
# 状态查看
# ------------------------------------------------------------
show_status() {
    echo "================= 当前状态 ================="
    echo "端口: $PORT"
    echo "限速: 上 $LIMIT_UP_MBPS Mbps / 下 $LIMIT_DOWN_MBPS Mbps"
    echo "最大IP数: $MAX_IPS"
    echo "封禁时长: $BAN_TIME 秒"
    echo "封禁模式: $BAN_MODE"
    echo "检测间隔: $CHECK_INTERVAL 分钟"
    echo "配置文件: $CONF_FILE"
    echo "-------------------------------------------"
    echo "Fail2ban 状态:"
    fail2ban-client status "$JAIL_NAME" 2>/dev/null || echo "Fail2ban 未运行"
    echo "==========================================="
}

# ------------------------------------------------------------
# 菜单交互
# ------------------------------------------------------------
main_menu() {
    init_config
    check_dependencies
    iface=$(detect_iface)
    echo "🌐 检测到主网卡: $iface"
    setup_systemd_service
    while true; do
        clear
        echo "======== Trojan-Go 限速 + 封禁 + 自启管理 ========"
        echo "1) 开启限速"
        echo "2) 关闭限速"
        echo "3) 修改限速"
        echo "4) 开启封禁"
        echo "5) 关闭封禁"
        echo "6) 解锁所有封禁"
        echo "7) 查看被封用户"
        echo "8) 修改最大允许IP数"
        echo "9) 修改封禁时长"
        echo "10) 切换封禁模式"
        echo "11) 修改检测间隔"
        echo "12) 查看当前状态"
        echo "0) 退出"
        read -p "选择操作: " opt
        case "$opt" in
            1) apply_limits; read -p "回车继续..." ;;
            2) clear_limits; read -p "回车继续..." ;;
            3) modify_limits; read -p "回车继续..." ;;
            4) enable_banning; read -p "回车继续..." ;;
            5) disable_banning; read -p "回车继续..." ;;
            6) unban_all; read -p "回车继续..." ;;
            7) show_banned; read -p "回车继续..." ;;
            8) modify_max_ips; read -p "回车继续..." ;;
            9) modify_ban_time; read -p "回车继续..." ;;
            10) modify_ban_mode; read -p "回车继续..." ;;
            11) modify_check_interval; read -p "回车继续..." ;;
            12) show_status; read -p "回车继续..." ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

# ------------------------------------------------------------
# systemd 启动逻辑
# ------------------------------------------------------------
if [[ "${1:-}" == "--autostart" ]]; then
    init_config
    apply_limits
    enable_banning
    exit 0
fi

main_menu
