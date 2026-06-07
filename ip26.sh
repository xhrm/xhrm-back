#!/bin/bash
set -euo pipefail

CONF_FILE="/etc/trojan-ban.conf"
CHECK_SCRIPT="/usr/local/bin/trojan-check.sh"
BAN_LOG="/var/log/trojan-ban.log"

# ================= OS =================
detect_os() {
    if [ -f /etc/debian_version ]; then
        OS="debian"
        PKG="apt install -y"
    else
        OS="centos"
        command -v dnf &>/dev/null && PKG="dnf install -y" || PKG="yum install -y"
    fi
}

# ================= CONFIG =================
init_config() {
    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<EOF
LOG_FILE="/etc/trojan-go/log.txt"
MAX_IPS=3
CHECK_INTERVAL=5
BAN_TIME=1800
EOF
    fi
    source "$CONF_FILE"
}

# ================= FAIL2BAN =================
install_fail2ban() {
    command -v fail2ban-client &>/dev/null || $PKG fail2ban

    systemctl enable fail2ban
    systemctl restart fail2ban

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
function parse(t, a) {
    gsub(/\//," ",t)
    gsub(/-/," ",t)
    gsub(/:/," ",t)
    split(t,a," ")
    return mktime(a[1]" "a[2]" "a[3]" " "a[4]" " "a[5]" " "a[6])
}

{
    if (match($0,/([0-9]{4}[\/-][0-9]{2}[\/-][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/,m)) {

        ts = parse(m[1])
        if (ts < since) next

        if ($0 ~ /user / && $0 ~ /from /) {
            match($0,/user ([^ ]+)/,u)
            match($0,/from ([0-9.]+):/,i)

            if (u[1] != "" && i[1] != "") {
                print u[1], i[1]
            }
        }
    }
}' "$LOG_FILE" > "$TMP"

while read -r user; do
    ips=$(grep "^$user " "$TMP" | awk '{print $2}' | sort -u)
    count=$(echo "$ips" | wc -w)

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

# ================= SYSTEMD =================
setup_systemd() {
cat > /etc/systemd/system/trojan-ban.service <<EOF
[Unit]
Description=Trojan Ban Check
After=network.target

[Service]
Type=oneshot
ExecStart=$CHECK_SCRIPT
EOF

cat > /etc/systemd/system/trojan-ban.timer <<EOF
[Unit]
Description=Trojan Ban Timer

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

# ================= CLEAN =================
clear_ban() {
    for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2); do
        ips=$(fail2ban-client status "$jail" | grep "Banned IP list" | cut -d: -f2)
        for ip in $ips; do
            fail2ban-client set "$jail" unbanip "$ip" || true
        done
    done
}

# ================= STATUS =================
show_status() {
    source "$CONF_FILE"

    echo "========================"
    echo " Trojan-Go 状态"
    echo "========================"

    systemctl is-active fail2ban &>/dev/null && echo "Fail2ban: RUNNING" || echo "Fail2ban: STOP"

    systemctl is-active trojan-ban.timer &>/dev/null && echo "Timer: RUNNING" || echo "Timer: STOP"

    echo ""
    echo "MAX_IPS=$MAX_IPS"
    echo "CHECK_INTERVAL=$CHECK_INTERVAL"

    total_ip=0
    for j in $(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2); do
        c=$(fail2ban-client status "$j" | grep "Banned IP list" | wc -w)
        total_ip=$((total_ip + c))
    done

    echo "BANNED IP TOTAL=$total_ip"

    user_count=$(grep "USER=" "$BAN_LOG" 2>/dev/null | awk -F"USER=" '{print $2}' | awk '{print $1}' | sort -u | wc -l)
    echo "BANNED USERS=$user_count"
}

# ================= DETAIL =================
show_detail() {
    echo "========================"
    echo " 用户封禁明细"
    echo "========================"

    [ ! -f "$BAN_LOG" ] && echo "no data" && return

    users=$(grep "USER=" "$BAN_LOG" | awk -F"USER=" '{print $2}' | awk '{print $1}' | sort -u)

    for u in $users; do
        echo ""
        echo "USER: $u"

        count=$(grep "USER=$u" "$BAN_LOG" | tail -1 | grep -oE "IP_COUNT=[0-9]+" | cut -d= -f2)
        echo "IP_COUNT=$count"

        ips=$(grep -A100 "USER=$u" "$BAN_LOG" | grep "BAN " | awk '{print $2}' | sort -u | xargs)
        echo "IPS=$ips"
    done
}

# ================= SERVICE =================
start() {
    init_config
    install_fail2ban
    gen_check_script
    setup_systemd
    "$CHECK_SCRIPT"
}

stop() {
    systemctl stop trojan-ban.timer 2>/dev/null || true
    systemctl disable trojan-ban.timer 2>/dev/null || true
    systemctl stop fail2ban || true
    clear_ban
}

# ================= MENU =================
menu() {
while true; do
    clear
    echo "==== Trojan-Go Ban ===="
    echo "1. 开启"
    echo "2. 关闭"
    echo "3. 清理封禁IP"
    echo "4. 修改IP数量"
    echo "5. 修改检测间隔"
    echo "6. 状态"
    echo "7. 用户明细"
    echo "0. 退出"

    read -p "选择: " c

    case $c in
        1) start ;;
        2) stop ;;
        3) clear_ban ;;
        4)
            read -p "MAX_IPS=" v
            sed -i "s/^MAX_IPS=.*/MAX_IPS=$v/" "$CONF_FILE"
            ;;
        5)
            read -p "INTERVAL=" v
            sed -i "s/^CHECK_INTERVAL=.*/CHECK_INTERVAL=$v/" "$CONF_FILE"
            ;;
        6) show_status ;;
        7) show_detail ;;
        0) exit 0 ;;
    esac

    read -p "Enter继续..."
done
}

# ================= MAIN =================
detect_os
init_config
menu
