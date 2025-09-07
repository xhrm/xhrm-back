#!/bin/bash
# ===========================================
# DNS 解锁一键脚本 (A + B 通用)
# 作者: xhrm
# ===========================================

CONFIG_DIR="/etc/dns-unlock"
DOMAIN_FILE="$CONFIG_DIR/domains.txt"
A_SERVER_IP=""
NORMAL_DNS1="8.8.8.8"
NORMAL_DNS2="1.1.1.1"
TEST_DOMAIN="netflix.com"

mkdir -p $CONFIG_DIR
touch $DOMAIN_FILE

# ========== 公共函数 ==========
install_pkg() {
    if [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y $1
    else
        apt-get update
        apt-get install -y $1
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

apply_smartdns_config() {
    if [ -z "$A_SERVER_IP" ]; then
        warn "尚未配置 A 服务器 IP，无法生成 smartdns 配置"
        return
    fi

    cat > /etc/smartdns/smartdns.conf <<EOF
bind [::]:53
cache-size 10240

# 正常DNS
server $NORMAL_DNS1
server $NORMAL_DNS2

# A服务器（初始启用）
#A_SERVER_START
server $A_SERVER_IP
EOF

    if [ -s "$DOMAIN_FILE" ]; then
        while read -r KEY; do
            [ -z "$KEY" ] && continue
            echo "domain-rules /.*$KEY.*/ -nameserver $A_SERVER_IP" >> /etc/smartdns/smartdns.conf
        done < "$DOMAIN_FILE"
    fi

    cat >> /etc/smartdns/smartdns.conf <<EOF
#A_SERVER_END

# 其它域名走正常DNS
nameserver /./$NORMAL_DNS1

# 故障切换和测速
speed-check-mode ping,tcp:80
EOF

    systemctl restart smartdns
    msg "smartdns 配置已更新并重启 (立即生效)"
}

add_domain() {
    read -p "请输入要添加的关键字(例如: instagram): " KEY
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
        echo "----------------------------"
        echo "1) 添加关键字"
        echo "2) 删除关键字"
        echo "3) 返回上级菜单"
        echo "============================"
        read -p "请选择 [1-3]: " opt
        case $opt in
            1) add_domain ;;
            2) del_domain ;;
            3) break ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ========== A 机器安装 ==========
install_A() {
    msg "开始安装 A 机器 (解锁 DNS 服务)..."
    install_pkg dnsmasq

    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%s)

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

    msg "A 机器部署完成！提供普通解析 + 解锁服务"
}

# ========== B 机器安装 ==========
install_B() {
    while true; do
        echo "==========================================="
        echo " B 机器 (智能分流客户端) 菜单"
        echo "==========================================="
        echo "1) 配置并安装 smartdns"
        echo "2) 管理解锁关键字 (立即生效)"
        echo "3) 返回主菜单"
        echo "==========================================="
        read -p "请选择 [1-3]: " subchoice

        case $subchoice in
            1)
                read -p "请输入 A 机器的公网IP: " A_SERVER_IP
                msg "使用 A 机器 IP: $A_SERVER_IP"

                install_pkg smartdns
                apply_smartdns_config

                echo "nameserver 127.0.0.1" > /etc/resolv.conf

                msg "smartdns 已配置完成！"

                # 健康检测脚本
                CHECK_SCRIPT="/usr/local/bin/check_a_dns.sh"
                cat > $CHECK_SCRIPT <<EOF
#!/bin/bash
SMARTDNS_CONF="/etc/smartdns/smartdns.conf"
A_SERVER_IP="$A_SERVER_IP"
DOMAIN_FILE="$DOMAIN_FILE"
TEST_DOMAIN="$TEST_DOMAIN"

check_dns() {
    dig @\$A_SERVER_IP \$TEST_DOMAIN +time=2 +tries=1 +short > /dev/null 2>&1
    return \$?
}

config_has_a() {
    grep -q "\$A_SERVER_IP" "\$SMARTDNS_CONF"
    return \$?
}

if check_dns; then
    if ! config_has_a; then
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
    fi
else
    if config_has_a; then
        sed -i "/#A_SERVER_START/,/#A_SERVER_END/d" "\$SMARTDNS_CONF"
        systemctl restart smartdns
    fi
fi
EOF

                chmod +x $CHECK_SCRIPT
                (crontab -l 2>/dev/null; echo "* * * * * $CHECK_SCRIPT >> /var/log/check_a_dns.log 2>&1") | crontab -

                msg "健康检测已启用，每分钟检查一次 A 机器 DNS"
                ;;
            2) manage_domains ;;
            3) break ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ========== 主入口 ==========
while true; do
    echo "==========================================="
    echo " DNS 解锁一键脚本 (A + B 通用)"
    echo "==========================================="
    echo " 1) 安装 A 机器 (解锁 DNS 服务)"
    echo " 2) 安装 B 机器 (智能分流客户端)"
    echo " 3) 退出"
    echo "==========================================="
    read -p "请选择模式 [1-3]: " choice

    case $choice in
        1) install_A ;;
        2) install_B ;;
        3) exit 0 ;;
        *) warn "无效选择" ;;
    esac
done
