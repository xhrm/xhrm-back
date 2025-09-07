install_A() {
    msg "开始安装 A 机器 (dnsmasq + HTTPS 透明代理)..."

    # 安装基础包
    install_pkg dnsmasq
    install_pkg stunnel4
    install_pkg iptables
    install_pkg curl
    install_sniproxy
    install_pkg iptables-persistent

    # 检测 systemd-resolved 是否占用 53 端口
    if systemctl is-active --quiet systemd-resolved; then
        msg "检测到 systemd-resolved 正在运行，占用 53 端口"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        msg "已停止并禁用 systemd-resolved"
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        msg "/etc/resolv.conf 已指向本地 dnsmasq"
    fi

    # 备份旧配置
    [ -f /etc/dnsmasq.conf ] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%s)

    # Debian/Ubuntu 兼容配置，server=IP 语法
    cat > /etc/dnsmasq.conf <<EOF
port=53
no-resolv
log-queries
log-facility=/var/log/dnsmasq.log
server=$NORMAL_DNS1
server=$NORMAL_DNS2
EOF

    # 启动 dnsmasq
    systemctl enable dnsmasq
    systemctl restart dnsmasq
    msg "dnsmasq 启动完成"

    # sniproxy 配置
    mkdir -p /etc/sniproxy
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
