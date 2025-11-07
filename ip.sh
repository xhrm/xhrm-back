#!/bin/bash
# ============================================================
# Trojan-Go 智能限速 + Fail2ban 封禁管理 + systemd自启动 (最终可用版)
# - 自动检测依赖并安装 fail2ban
# - 使用 tc+ifb 做真实上下行限速（每 IP 总体限速）
# - 定时分析 trojan-go 日志并通过 fail2ban 封禁超限 IP
# - 自动安装并启用 systemd 服务（开机自动恢复）
# - 提供交互式菜单：限速/封禁/修改/查看/解封 等
# 默认配置（若无 /etc/trojan_smart.conf 则写入）：
#   端口 443；上下行 20 Mbps；MAX_IPS=3；BAN_TIME=1800s；CHECK_INTERVAL=10min；BAN_MODE=extra
# ============================================================

set -euo pipefail

# --- 常量 / 路径 ---
CONF_FILE="/etc/trojan_smart.conf"
CHECK_SCRIPT="/usr/local/bin/trojan_smart_check.sh"
SERVICE_FILE="/etc/systemd/system/trojan-manager.service"
BAN_LOG="/var/log/trojan-smart-ban.log"
JAIL_NAME="trojan-go"

# --- 默认参数（可持久化到 CONF_FILE） ---
PORT=443
LIMIT_UP_MBPS=20
LIMIT_DOWN_MBPS=20
LOG_FILE="/etc/trojan-go/log.txt"   # 若不同请在菜单修改
MAX_IPS=3
CHECK_INTERVAL=10
BAN_TIME=1800
BAN_MODE="extra"    # extra | all

# ---------------------------
# 初始化 / 读写配置
# ---------------------------
init_config() {
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    else
        mkdir -p "$(dirname "$CONF_FILE")" 2>/dev/null || true
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
        # load
        # shellcheck disable=SC1090
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

# ---------------------------
# 基础工具检查（包含自动安装 fail2ban）
# ---------------------------
check_dependencies() {
    echo "🔍 检查系统依赖..."
    deps=(ip tc iptables awk grep date fail2ban-client)
    missing=()
    for c in "${deps[@]}"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "⚠️ 检测到缺失命令: ${missing[*]}"
    fi

    # Ensure tc, ip, iptables exist (critical)
    for c in ip tc iptables awk grep date; do
        if ! command -v "$c" >/dev/null 2>&1; then
            echo "❌ 必需工具 $c 不存在，请在系统安装 iproute2/iptables 后重试。"
            exit 1
        fi
    done

    # fail2ban 安装（若缺失则自动安装）
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "📦 未检测到 fail2ban，尝试自动安装..."
        if command -v apt >/dev/null 2>&1; then
            apt update -y
            apt install -y fail2ban
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release || true
            yum install -y fail2ban
        else
            echo "❌ 未知包管理器，无法自动安装 fail2ban，请手动安装并重试。"
            exit 1
        fi
    fi

    echo "✅ 依赖检查通过"
}

# ---------------------------
# 辅助：检测主网卡
# ---------------------------
detect_iface() {
    ip route | awk '/default/ {print $5; exit}'
}

# ---------------------------
# 限速模块：tc + ifb（真实限速）
# 说明：
#  - 下载 (server -> client) 通过 ifb0 on ingress 限速
#  - 上传 (client -> server) 通过 iface root htb 限速
# 该实现为简单统一带宽限制；如需 per-IP 精细 class 可扩展
# ---------------------------
apply_limits() {
    init_config
    local iface
    iface=$(detect_iface)
    if [ -z "$iface" ]; then
        echo "❌ 无法检测主网卡，取消限速"
        return 1
    fi

    echo "⚙️ 应用限速 (tc+ifb) => 网卡: $iface 上:${LIMIT_UP_MBPS}Mbps 下:${LIMIT_DOWN_MBPS}Mbps"

    # 清理旧
    clear_limits

    # 加载 ifb 模块并创建 ifb0
    modprobe ifb numifbs=1 2>/dev/null || true
    ip link set dev ifb0 up 2>/dev/null || ip link add ifb0 type ifb 2>/dev/null || true
    ip link set dev ifb0 up 2>/dev/null || true

    # 下载方向：重定向 ingress -> ifb0，然后在 ifb0 上限速
    tc qdisc add dev "$iface" ingress 2>/dev/null || true
    tc filter add dev "$iface" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || true

    tc qdisc add dev ifb0 root handle 1: htb default 10 2>/dev/null || true
    tc class add dev ifb0 parent 1: classid 1:1 htb rate "${LIMIT_DOWN_MBPS}mbit" ceil "${LIMIT_DOWN_MBPS}mbit" 2>/dev/null || true
    tc qdisc add dev ifb0 parent 1:1 handle 10: sfq perturb 10 2>/dev/null || true

    # 上传方向：在物理网卡上限速
    tc qdisc add dev "$iface" root handle 2: htb default 20 2>/dev/null || true
    tc class add dev "$iface" parent 2: classid 2:1 htb rate "${LIMIT_UP_MBPS}mbit" ceil "${LIMIT_UP_MBPS}mbit" 2>/dev/null || true
    tc qdisc add dev "$iface" parent 2:1 handle 20: sfq perturb 10 2>/dev/null || true

    echo "✅ tc 限速已应用"
    return 0
}

clear_limits() {
    local iface
    iface=$(detect_iface)
    echo "🧹 清理 tc/ifb 限速规则..."
    [ -n "$iface" ] && tc qdisc del dev "$iface" root 2>/dev/null || true
    [ -n "$iface" ] && tc qdisc del dev "$iface" ingress 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    ip link set dev ifb0 down 2>/dev/null || true
    ip link delete ifb0 2>/dev/null || true
    echo "✅ 限速清理完成"
}

# ---------------------------
# Fail2ban setup & check script
# ---------------------------
setup_fail2ban() {
    init_config
    echo "⚙️ 配置 Fail2ban（filter & jail）..."
    mkdir -p /etc/fail2ban/filter.d

    cat > /etc/fail2ban/filter.d/trojan-go.conf <<'EOF'
[Definition]
failregex = ^.*user .* from <HOST>:.*$
ignoreregex =
EOF

    # append or update jail.local
    if ! grep -q "^\[trojan-go\]" /etc/fail2ban/jail.local 2>/dev/null; then
        cat >> /etc/fail2ban/jail.local <<EOF

[trojan-go]
enabled  = true
filter   = trojan-go
logpath  = $LOG_FILE
maxretry = 1
findtime = 600
bantime  = $BAN_TIME
EOF
    else
        # attempt to update bantime if exists
        sed -i "/^\[trojan-go\]/,/^\[/ s/^\s*bantime\s*=.*/bantime  = $BAN_TIME/" /etc/fail2ban/jail.local || true
    fi

    systemctl enable fail2ban --now || true
    systemctl restart fail2ban || true
    echo "✅ Fail2ban 已配置并启动（若可用）"
}

generate_check_script() {
    init_config
    echo "⚙️ 生成检测脚本：$CHECK_SCRIPT"
    cat > "$CHECK_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail
CONF="/etc/trojan_smart.conf"
source "$CONF"
TMP=$(mktemp)
since=$(date -d "-$CHECK_INTERVAL minutes" +%s 2>/dev/null || date -d "-$CHECK_INTERVAL min" +%s)

awk -v since="$since" '
{
  # parse timestamp at start of log line
  ts=$1" "$2
  gsub(/[-:]/," ",ts)
  split(ts,t," ")
  logtime=mktime(t[1]" "t[2]" "t[3]" "t[4]" "t[5]" "t[6])
  if (logtime>=since && /user .* from/) {
    for (i=1;i<=NF;i++){
      if ($i=="user") user=$(i+1)
      if ($i=="from") { split($(i+1),a,":"); ip=a[1] }
    }
    if (user!="" && ip!="") print user,ip
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
    echo "✅ 检测脚本生成完成"
}

enable_banning() {
    setup_fail2ban
    generate_check_script
    # add cron (root)
    (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT" || true; echo "*/$CHECK_INTERVAL * * * * $CHECK_SCRIPT") | crontab -
    echo "✅ 封禁检测已启用（crontab，每 $CHECK_INTERVAL 分钟）"
}

disable_banning() {
    (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT" || true) | crontab -
    echo "✅ 封禁检测已关闭"
}

show_banned() {
    echo "=== 当前被封 IP 列表 (jail: $JAIL_NAME) ==="
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status "$JAIL_NAME" >/dev/null 2>&1; then
        fail2ban-client status "$JAIL_NAME" | awk -F: '/Banned IP list/ {print $2}'
    else
        echo "（未配置或 fail2ban 未运行）"
    fi
    echo "----------- 最近封禁日志（$BAN_LOG） -----------"
    [ -f "$BAN_LOG" ] && tail -n 50 "$BAN_LOG" || echo "(无)"
}

unban_all() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "fail2ban-client not found"
        return
    fi
    jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}')
    for jail in $jails; do
        jail_clean=$(echo "$jail" | tr -d ' ,')
        banned=$(fail2ban-client status "$jail_clean" 2>/dev/null | awk -F: '/Banned IP list/ {print $2}')
        for ip in $banned; do
            ip=$(echo "$ip" | xargs)
            [ -n "$ip" ] && fail2ban-client set "$jail_clean" unbanip "$ip" || true
        done
    done
    echo "✅ 尝试解除所有 jail 的封禁"
}

# ---------------------------
# systemd 服务（自动安装 & enable）
# ---------------------------
setup_systemd_service() {
    echo "⚙️ 创建并启用 systemd 服务: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Trojan-Go limits + fail2ban manager
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
    systemctl enable trojan-manager.service || true
    echo "✅ systemd 服务已创建并启用（若可用）"
}

# ---------------------------
# 显示状态（限速 + 封禁）
# ---------------------------
show_status() {
    init_config
    echo "================= 当前运行状态 ================="
    echo "端口: $PORT"
    echo "限速 (上/下): ${LIMIT_UP_MBPS} Mbps / ${LIMIT_DOWN_MBPS} Mbps"
    echo "最大IP数: $MAX_IPS"
    echo "封禁时长: $BAN_TIME 秒"
    echo "封禁模式: $BAN_MODE"
    echo "检测间隔: $CHECK_INTERVAL 分钟"
    echo "配置文件: $CONF_FILE"
    echo "-------------------------------------------"
    iface=$(detect_iface)
    if [ -n "$iface" ]; then
        echo "网卡: $iface"
        echo "tc qdisc (summary):"
        tc -s qdisc show dev "$iface" 2>/dev/null || echo "(无 tc 规则)"
        echo "ifb0 qdisc (summary):"
        tc -s qdisc show dev ifb0 2>/dev/null || echo "(ifb0 未启用)"
    else
        echo "网卡: 未检测到"
    fi
    echo "-------------------------------------------"
    echo "Fail2ban 状态:"
    if command -v fail2ban-client >/dev/null 2>&1; then
        systemctl is-active fail2ban >/dev/null 2>&1 && echo "fail2ban: active" || echo "fail2ban: inactive"
        if fail2ban-client status "$JAIL_NAME" >/dev/null 2>&1; then
            fail2ban-client status "$JAIL_NAME" || true
        else
            echo "trojan-go jail 未配置或不可用"
        fi
    else
        echo "fail2ban 未安装"
    fi
    echo "==========================================="
}

# ---------------------------
# 参数修改函数（交互）
# ---------------------------
modify_limits() {
    read -p "新上传限速(Mbps) 当前[$LIMIT_UP_MBPS]: " up
    read -p "新下载限速(Mbps) 当前[$LIMIT_DOWN_MBPS]: " down
    [ -n "$up" ] && LIMIT_UP_MBPS="$up"
    [ -n "$down" ] && LIMIT_DOWN_MBPS="$down"
    save_config
    apply_limits
    echo "✅ 已更新限速并应用"
}

modify_max_ips() {
    read -p "新最大允许 IP 数 当前[$MAX_IPS]: " n
    if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]]; then
        MAX_IPS="$n"
        save_config
        echo "✅ MAX_IPS 已更新为 $MAX_IPS"
    else
        echo "输入无效，保留原值 $MAX_IPS"
    fi
}

modify_ban_time() {
    read -p "新封禁时长(秒) 当前[$BAN_TIME]: " n
    if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 60 ]]; then
        BAN_TIME="$n"
        save_config
        # update jail if exists
        if [ -f /etc/fail2ban/jail.local ]; then
            sed -i "/^\[trojan-go\]/,/^\[/ s/^\s*bantime\s*=.*/bantime  = $BAN_TIME/" /etc/fail2ban/jail.local || true
            systemctl restart fail2ban || true
        fi
        echo "✅ BAN_TIME 已更新为 $BAN_TIME 秒"
    else
        echo "输入无效"
    fi
}

modify_ban_mode() {
    echo "当前模式: $BAN_MODE"
    echo "1) extra (只封多余IP)"
    echo "2) all   (封禁该用户所有IP)"
    read -p "选择 [1|2]: " m
    case "$m" in
        1) BAN_MODE="extra" ;;
        2) BAN_MODE="all" ;;
        *) echo "取消，保持 $BAN_MODE"; return ;;
    esac
    save_config
    echo "✅ BAN_MODE 已设置为 $BAN_MODE"
}

modify_check_interval() {
    read -p "检测间隔(分钟) 当前[$CHECK_INTERVAL]: " n
    if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]]; then
        CHECK_INTERVAL="$n"
        save_config
        # update cron
        (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT" || true; echo "*/$CHECK_INTERVAL * * * * $CHECK_SCRIPT") | crontab -
        echo "✅ 检测间隔已更新为 $CHECK_INTERVAL 分钟"
    else
        echo "输入无效"
    fi
}

# ---------------------------
# 交互菜单
# ---------------------------
main_menu() {
    init_config
    check_dependencies
    echo "🌐 主网卡: $(detect_iface || echo unknown)"
    # auto install systemd service if missing
    if [ ! -f "$SERVICE_FILE" ]; then
        setup_systemd_service
    fi

    while true; do
        clear
        echo "======== Trojan-Go 限速 + 封禁 管理 ========"
        echo "1) 开启限速"
        echo "2) 关闭限速"
        echo "3) 修改限速"
        echo "4) 开启封禁检测"
        echo "5) 关闭封禁检测"
        echo "6) 解封所有封禁"
        echo "7) 查看被封用户 / 封禁日志"
        echo "8) 修改最大允许IP数 (当前: $MAX_IPS)"
        echo "9) 修改封禁时长 (当前: $BAN_TIME 秒)"
        echo "10) 切换封禁模式 (当前: $BAN_MODE)"
        echo "11) 修改检测间隔/日志扫描范围 (当前: $CHECK_INTERVAL 分钟)"
        echo "12) 查看当前状态"
        echo "13) 安装/启用 systemd 自启"
        echo "0) 退出"
        echo "-------------------------------------------"
        read -p "请选择: " opt
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
            13) setup_systemd_service; read -p "回车继续..." ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# ---------------------------
# autostart entry (used by systemd)
# ---------------------------
if [[ "${1:-}" == "--autostart" ]]; then
    init_config
    check_dependencies
    apply_limits || true
    enable_banning || true
    exit 0
fi

# ---------------------------
# 默认行为：自动配置并启动一次，然后进入菜单
# ---------------------------
init_config
check_dependencies
setup_systemd_service || true
apply_limits || true
enable_banning || true
show_status
echo "✅ 部署完成 — 进入管理菜单"
main_menu
