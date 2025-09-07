#!/bin/bash
# ===========================================
# DNS 解锁一键脚本 (A + B 通用) - Debian/Ubuntu 版
# 支持 A: dnsmasq + sniproxy + stunnel HTTPS透明代理 + 永久iptables
# 支持 B: smartdns 分流客户端，关键字立即生效
# 自动处理 systemd-resolved 占用 53 端口问题
# 作者: xhrm
# ===========================================

set -euo pipefail

CONFIG_DIR="/etc/dns-unlock"
DOMAIN_FILE="$CONFIG_DIR/domains.txt"
A_SERVER_IP=""
NORMAL_DNS1="8.8.8.8"
NORMAL_DNS2="1.1.1.1"
TEST_DOMAIN="netflix.com"

mkdir -p "$CONFIG_DIR"
touch "$DOMAIN_FILE"

# ================= 公共函数 =================
install_pkg() {
    local pkg=$1
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y "$pkg"
    fi
}

msg() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }

show_domains() {
    echo "当前关键字列表:"
    if [ -s "$DOMAIN_FILE" ]; then
        nl -w2 -s". " "$DOMAIN_FILE"
    else
        echo "(空)"
    fi
}

# ================= B 机器 smartdns 配置 =================
apply_smartdns_config() {
    if [ -z "$A_SERVER_IP" ]; then
        warn "尚未配置 A 服务器 IP，无法生成 smartdns 配置"
        return
    fi

    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak.$(date +%s)

    cat > /etc/smartdns/smartdns.conf <<EOF
bind [::]:53
cache-size 10240

# 普通 DNS
server=$NORMAL_DNS1
server=$NORMAL_DNS2

# A 服务器（解锁机）
#A_SERVER_START
server=$A_SERVER_IP
EOF

    if [ -s "$DOMAIN_FILE" ]; then
        while read -r KEY; do
            [ -z "$KEY" ] && continue
            echo "domain-rules /.*$KEY.*/ -nameserver $A_SERVER_IP" >> /etc/smartdns/smartdns.conf
        done < "$DOMAIN_FILE"
    fi

    cat >> /etc/smartdns/smartdns.conf <<EOF
#A_SERVER_END

# 默认走普通 DNS
nameserver /./$NORMAL_DNS1

# 故障切换和测速
speed-check-mode ping,tcp:80
EOF

    systemctl enable smartdns
    systemctl restart smartdns
    msg "smartdns 配置已更新并重启 (立即生效)"
}

# ================= B 机器关键字管理 =================
add_domain() {
    read -p "请输入关键字(例如 instagram): " KEY
    if grep -qx "$KEY" "$DOMAIN_FILE"; then
        warn "关键字已存在: $KEY"
    else
        echo "$KEY" >> "$DOMAIN_FILE"
        msg "已添加关键字: $KEY"
        apply_smartdns_config
    fi
}

del_domain() {
    show_domains
    read -p "请输入要删除的序号: " IDX
    if sed -n "${IDX}p" "$DOMAIN_FILE" >/dev/null 2>&1; then
        KEY=$(sed -n "${IDX}p" "$DOMAIN_FILE")
        sed -i "${IDX}d" "$DOMAIN_FILE"
        msg "已删除关键字: $KEY"
        apply_smartdns_config
    else
        warn "无效序号"
    fi
}

manage_domains() {
    while true; do
        echo "============================"
        echo " 域名关键字管理 ($DOMAIN_FILE)"
        echo "============================"
        show_domains
        echo "1) 添加关键字"
        echo "2) 删除关键字"
        echo "3) 返回"
        read -p "请选择 [1-3]: " opt
        case $opt in
            1) add_domain ;;
            2) del_domain ;;
            3) break ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ================= 安装 sniproxy =================
install_sniproxy() {
    msg "开始安装 sniproxy..."
    install_pkg sniproxy
    mkdir -p /etc/sniproxy
    cat >/etc/systemd/system/sniproxy.service <<EOF
[Unit]
Description=SNI Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sniproxy -c /etc/sniproxy/sniproxy.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sniproxy
    systemctl restart sniproxy
    msg "sniproxy 安装完成并已启动"
}

# ================= A 机器安装 =================
install_A() {
    msg "开始安装 A 机器 (dnsmasq + HTTPS 透明代理)..."

    install_pkg dnsmasq
    install_pkg stunnel4
    install_pkg iptables
    install_pkg curl
    install_sniproxy
    install_pkg iptables-persistent

    # 处理 systemd-resolved 占用 53 端口
    if systemctl is-active --quiet systemd-resolved; then
        msg "检测到 systemd-resolved 正在运行，占用 53 端口"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        msg "已停止 systemd-resolved 并指向本地 dnsmasq"
    fi

    # 备份旧配置
    [ -f /etc/dnsmasq.conf ] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%s)

    # Debian/Ubuntu 兼容 dnsmasq 配置
    cat > /etc/dnsmasq.conf <<EOF
port=53
no-resolv
log-queries
log-facility=/var/log/dnsmasq.log
server=$NORMAL_DNS1
server=$NORMAL_DNS2
EOF

    systemctl enable dnsmasq
    systemctl restart dnsmasq
    msg "dnsmasq 启动完成"

    # sniproxy 配置
    cat > /etc/sniproxy/sniproxy.conf <<EOF
user nobody
pidfile /var/run/sniproxy.pid

listen 127.0.0.1:8443 {
    proto tls
}

table {
    .* 127.0.0.1:8443
}
EOF
    systemctl restart sniproxy

    # stunnel 配置
    mkdir -p /etc/stunnel
    cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
foreground = no
[https]
accept = 8443
connect = 127.0.0.1:8443
cert = /etc/stunnel/stunnel.pem
EOF
    if [ ! -f /etc/stunnel/stunnel.pem ]; then
        openssl req -new -x509 -days 3650 -nodes \
        -out /etc/stunnel/stunnel.pem -keyout /etc/stunnel/stunnel.pem \
        -subj "/CN=A-Machine"
    fi
    systemctl enable stunnel4
    systemctl restart stunnel4

    # iptables HTTPS 重定向
    iptables -t nat -F
    iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 8443
    netfilter-persistent save
    netfilter-persistent reload

    msg "A 机器部署完成，HTTPS透明代理生效，iptables规则已保存"
}

# ================= B 机器安装 =================
install_B() {
    while true; do
        echo "==========================================="
        echo " B 机器 (智能分流客户端) 菜单"
        echo "==========================================="
        echo "1) 配置并安装 smartdns"
        echo "2) 管理解锁关键字 (立即生效)"
        echo "3) 返回主菜单"
        read -p "请选择 [1-3]: " subchoice

        case $subchoice in
            1)
                read -p "请输入 A 机器公网 IP: " A_SERVER_IP
                msg "使用 A 机器 IP: $A_SERVER_IP"
                install_pkg smartdns
                apply_smartdns_config

                grep -q "127.0.0.1" /etc/resolv.conf || sed -i '1inameserver 127.0.0.1' /etc/resolv.conf

                CHECK_SCRIPT="/usr/local/bin/check_a_dns.sh"
                cat > "$CHECK_SCRIPT" <<EOF
#!/bin/bash
SMARTDNS_CONF="/etc/smartdns/smartdns.conf"
A_SERVER_IP="$A_SERVER_IP"
DOMAIN_FILE="$DOMAIN_FILE"
TEST_DOMAIN="$TEST_DOMAIN"

check_dns() {
    dig @\$A_SERVER_IP \$TEST_DOMAIN +time=2 +tries=1 +short >/dev/null 2>&1
}

update_smartdns() {
    sed -i "/#A_SERVER_START/,/#A_SERVER_END/d" "\$SMARTDNS_CONF"
    {
        echo "#A_SERVER_START"
        echo "server \$A_SERVER_IP"
        while read -r KEY; do
            [ -z "\$KEY" ] && continue
            echo "domain-rules /.*\$KEY.*/ -nameserver \$A_SERVER_IP"
        done < "\$DOMAIN_FILE"
        echo "#A_SERVER_END"
    } >> "\$SMARTDNS_CONF"
    systemctl restart smartdns
}

if check_dns; then
    update_smartdns
else
    sed -i "/#A_SERVER_START/,/#A_SERVER_END/d" "\$SMARTDNS_CONF"
    systemctl restart smartdns
fi
EOF
                chmod +x "$CHECK_SCRIPT"
                (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT"; echo "* * * * * $CHECK_SCRIPT >> /var/log/check_a_dns.log 2>&1") | crontab -
                msg "健康检测已启用，每分钟检查一次 A 机器 DNS"
                ;;
            2) manage_domains ;;
            3) break ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ================= 主入口 =================
while true; do
    echo "==========================================="
    echo " DNS 解锁一键脚本 (A + B 通用) - Debian/Ubuntu 版"
    echo "==========================================="
    echo " 1) 安装 A 机器 (dnsmasq + HTTPS 透明代理)"
    echo " 2) 安装 B 机器 (smartdns 分流客户端)"
    echo " 3) 退出"
    read -p "请选择模式 [1-3]: " choice

    case $choice in
        1) install_A ;;
        2) install_B ;;
        3) exit 0 ;;
        *) warn "无效选择" ;;
    esac
done
