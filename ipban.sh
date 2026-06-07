#!/bin/bash
set -euo pipefail

CONF_FILE="/etc/trojan-ban.conf"
CHECK_SCRIPT="/usr/local/bin/trojan-check.sh"
LOG_FILE_DEFAULT="/etc/trojan-go/log.txt"
BAN_LOG="/var/log/trojan-ban.log"

# ================= OS =================
detect_os() {
    if [ -f /etc/debian_version ]; then
        OS="debian"
        PKG_INSTALL="apt install -y"
        CRON_SERVICE="cron"
        CRON_CMD="cron"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        if command -v dnf &>/dev/null; then
            PKG_INSTALL="dnf install -y"
            CRON_CMD="crond"
        else
            PKG_INSTALL="yum install -y"
            CRON_CMD="crond"
        fi
        CRON_SERVICE="crond"
    else
        echo "不支持系统"
        exit 1
    fi
}

# ================= CONFIG =================
init_config() {
    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<EOF
LOG_FILE="$LOG_FILE_DEFAULT"
MAX_IPS=3
CHECK_INTERVAL=5
BAN_TIME=1800
EOF
    fi
    source "$CONF_FILE"
}

# ================= FAIL2BAN =================
install_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        $PKG_INSTALL fail2ban
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban

    mkdir -p /etc/fail2ban/filter.d/

    cat > /etc/fail2ban/filter.d/trojan-go.conf <<EOF
[Definition]
failregex = .*user .* from <HOST>:
ignoreregex =
EOF

    cat > /etc/fail2ban/jail.local <<EOF
[trojan-go]
enabled = true
filter = trojan-go
logpath = $LOG_FILE
maxretry = 1
findtime = 600
bantime = $BAN_TIME
EOF

    systemctl restart fail2ban
}

# ================= CHECK SCRIPT =================
gen_check_script() {
cat > "$CHECK_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

source /etc/trojan-ban.conf

TMP=$(mktemp)

since=$(date -d "-$CHECK_INTERVAL minutes" +%s)

awk -v since="$since" '
function parse_time(t,   a) {
    gsub(/\//," ",t)
    gsub(/-/," ",t)
    gsub(/:/," ",t)
    split(t,a," ")
    return mktime(a[1]" "a[2]" "a[3]" "a[4]" "a[5]" "a[6])
}

{
    if (match($0, /([0-9]{4}[\/-][0-9]{2}[\/-][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, m)) {
        t = parse_time(m[1])
        if (t < since) next

        if ($0 ~ /user / && $0 ~ /from /) {
            match($0, /user ([a-zA-Z0-9]+)/, u)
            match($0, /from ([0-9.]+):/, i)

            user = u[1]
            ip = i[1]

            if (user != "" && ip != "") {
                print user, ip
            }
        }
    }
}' "$LOG_FILE" > "$TMP"

while read -r user; do
    ips=$(grep "^$user " "$TMP" | awk '{print $2}' | sort -u)
    count=$(echo "$ips" | wc -l)

    if [ "$count" -ge "$MAX_IPS" ]; then
        echo "[$(date '+%F %T')] USER=$user IP_COUNT=$count" >> "$BAN_LOG"

        for ip in $ips; do
            echo "BAN $ip" >> "$BAN_LOG"
            fail2ban-client set trojan-go banip "$ip"
        done
    fi
done < <(cut -d' ' -f1 "$TMP" | sort -u)

rm -f "$TMP"
EOF

chmod +x "$CHECK_SCRIPT"
}

# ================= SERVICE =================
setup_systemd() {
cat > /etc/systemd/system/trojan-ban.service <<EOF
[Unit]
Description=Trojan IP Ban Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=$CHECK_SCRIPT
EOF

cat > /etc/systemd/system/trojan-ban.timer <<EOF
[Unit]
Description=Run Trojan IP Ban every interval

[Timer]
OnBootSec=30sec
OnUnitActiveSec=${CHECK_INTERVAL}min
Unit=trojan-ban.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable trojan-ban.timer
systemctl start trojan-ban.timer
}

# ================= START =================
start_service() {
    init_config
    install_fail2ban
    gen_check_script
    setup_systemd

    # 立即执行一次
    "$CHECK_SCRIPT"
}

# ================= STOP =================
stop_service() {
    systemctl stop trojan-ban.timer 2>/dev/null || true
    systemctl disable trojan-ban.timer 2>/dev/null || true

    systemctl stop fail2ban || true

    # 解封
    for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2); do
        ips=$(fail2ban-client status "$jail" | grep "Banned IP list" | cut -d: -f2)
        for ip in $ips; do
            fail2ban-client set "$jail" unbanip "$ip" || true
        done
    done
}

# ================= CLEAN =================
clear_ban() {
    for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2); do
        ips=$(fail2ban-client status "$jail" | grep "Banned IP list" | cut -d: -f2)
        for ip in $ips; do
            fail2ban-client set "$jail" unbanip "$ip" || true
        done
    done
}

# ================= MENU =================
menu() {
while true; do
    clear
    echo "==== Trojan-Go IP Ban ===="
    echo "1. 开启功能"
    echo "2. 关闭功能"
    echo "3. 清理所有封禁IP"
    echo "4. 修改允许IP数量"
    echo "5. 修改检测间隔"
    echo "0. 退出"
    read -p "选择: " c

    case $c in
        1) start_service ;;
        2) stop_service ;;
        3) clear_ban ;;
        4)
            read -p "MAX_IPS: " v
            sed -i "s/^MAX_IPS=.*/MAX_IPS=$v/" "$CONF_FILE"
            ;;
        5)
            read -p "INTERVAL(min): " v
            sed -i "s/^CHECK_INTERVAL=.*/CHECK_INTERVAL=$v/" "$CONF_FILE"
            ;;
        0) exit 0 ;;
    esac
    read -p "回车继续..."
done
}

# ================= MAIN =================
detect_os
init_config
menu
