#!/bin/bash
# 文件名: fix_dns_menu.sh
# 功能: 菜单修改 DNS + 实时生效 + 开机自启 + 自动监控

# 检查 root
[ "$EUID" -ne 0 ] && echo "请使用 root 运行" && exit 1

RESOLV_FILE="/etc/resolv.conf"
SERVICE_FILE="/etc/systemd/system/fix_dns.service"
SCRIPT_FILE="/usr/local/bin/fix_dns_service.sh"
CONFIG_FILE="/etc/fix_dns_current.conf"

# 默认 DNS
DEFAULT_DNS1="8.8.8.8"
DEFAULT_DNS2="1.1.1.8"

# 验证 IP 地址格式
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        for octet in ${ip//./ }; do
            [ "$octet" -gt 255 ] && return 1
        done
        return 0
    fi
    return 1
}

# -------------------------
# 生成后台修复脚本
# -------------------------
create_service_script() {
    cat > "$SCRIPT_FILE" <<EOF
#!/bin/bash
RESOLV_FILE="$RESOLV_FILE"
CONFIG_FILE="$CONFIG_FILE"

# 读取配置
if [ -f "\$CONFIG_FILE" ]; then
    source "\$CONFIG_FILE"
else
    DNS1="$DEFAULT_DNS1"
    DNS2="$DEFAULT_DNS2"
fi

# 修复 resolv.conf
fix_resolv_conf() {
    [ -L "\$RESOLV_FILE" ] && rm -f "\$RESOLV_FILE" && touch "\$RESOLV_FILE"
    chattr -i "\$RESOLV_FILE" 2>/dev/null
    echo -e "nameserver \$DNS1\nnameserver \$DNS2" > "\$RESOLV_FILE"
    chattr +i "\$RESOLV_FILE"
    echo "\$(date '+%F %T') DNS 已设置为: \$DNS1, \$DNS2"
}

# NetworkManager 模式
set_dns_nm() {
    if command -v nmcli >/dev/null 2>&1; then
        CONN=\$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep -v ":$" | head -n1 | cut -d: -f1)
        if [ -n "\$CONN" ]; then
            nmcli con mod "\$CONN" ipv4.ignore-auto-dns yes
            nmcli con mod "\$CONN" ipv4.dns "\$DNS1 \$DNS2"
            nmcli con up "\$CONN" 2>/dev/null
        fi
    fi
    fix_resolv_conf
}

# network 模式
set_dns_network() {
    if [ -d "/etc/sysconfig/network-scripts" ]; then
        IFACE=\$(ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v ifcfg-lo | head -n1)
        if [ -n "\$IFACE" ]; then
            sed -i '/^DNS[0-9]=/d' "\$IFACE"
            echo "DNS1=\$DNS1" >> "\$IFACE"
            echo "DNS2=\$DNS2" >> "\$IFACE"
            systemctl restart network 2>/dev/null
        fi
    fi
    fix_resolv_conf
}

# 手动模式
set_dns_manual() { 
    fix_resolv_conf
}

# 检测模式
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    MODE="NM"
elif systemctl is-active --quiet network 2>/dev/null; then
    MODE="NETWORK"
else
    MODE="MANUAL"
fi

# 初始修复
case "\$MODE" in
    NM) set_dns_nm ;;
    NETWORK) set_dns_network ;;
    MANUAL) set_dns_manual ;;
esac

# 持续监控 DNS
while true; do
    sleep 60
    if [ -f "\$RESOLV_FILE" ]; then
        if ! grep -q "\$DNS1" "\$RESOLV_FILE" || ! grep -q "\$DNS2" "\$RESOLV_FILE"; then
            echo "\$(date '+%F %T') 检测到 DNS 被覆盖，正在修复..."
            case "\$MODE" in
                NM) set_dns_nm ;;
                NETWORK) set_dns_network ;;
                MANUAL) set_dns_manual ;;
            esac
        fi
    fi
done
EOF

    chmod +x "$SCRIPT_FILE"
}

# -------------------------
# 创建 systemd 服务
# -------------------------
create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=自动修复 DNS 劫持并锁定
After=network.target NetworkManager.service
Wants=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_FILE
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable fix_dns.service
    systemctl restart fix_dns.service
}

# 设置 DNS 的函数
set_dns() {
    local dns1=$1
    local dns2=$2
    
    # 保存配置
    echo "DNS1=$dns1" > "$CONFIG_FILE"
    echo "DNS2=$dns2" >> "$CONFIG_FILE"
    
    # 立即生效
    if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
        CONN=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep -v ":$" | head -n1 | cut -d: -f1)
        if [ -n "$CONN" ]; then
            nmcli con mod "$CONN" ipv4.ignore-auto-dns yes
            nmcli con mod "$CONN" ipv4.dns "$dns1 $dns2"
            nmcli con up "$CONN" 2>/dev/null
        fi
    elif systemctl is-active --quiet network 2>/dev/null && [ -d "/etc/sysconfig/network-scripts" ]; then
        IFACE=$(ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v ifcfg-lo | head -n1)
        if [ -n "$IFACE" ]; then
            sed -i '/^DNS[0-9]=/d' "$IFACE"
            echo "DNS1=$dns1" >> "$IFACE"
            echo "DNS2=$dns2" >> "$IFACE"
            systemctl restart network 2>/dev/null
        fi
    fi
    
    # 手动模式或通用锁定
    chattr -i "$RESOLV_FILE" 2>/dev/null
    echo -e "nameserver $dns1\nnameserver $dns2" > "$RESOLV_FILE"
    chattr +i "$RESOLV_FILE"
    
    # 重启服务以应用新配置
    systemctl restart fix_dns.service 2>/dev/null
    
    echo "✅ DNS 已修改为: $dns1, $dns2"
}

# -------------------------
# 主程序
# -------------------------

# 创建必要的文件
touch "$CONFIG_FILE"

# 生成脚本和服务
create_service_script
create_systemd_service

# 菜单循环
while true; do
    echo ""
    echo "=============================="
    echo "      DNS 管理菜单"
    echo "=============================="
    echo "1) 修改 DNS（手动输入）"
    echo "2) 显示当前 DNS"
    echo "3) 退出"
    echo "=============================="
    read -p "请选择 [1-3]: " CHOICE

    case "$CHOICE" in
        1)
            while true; do
                read -p "请输入 DNS1 (例如: 8.8.8.8): " input_dns1
                validate_ip "$input_dns1" && break
                echo "❌ IP 格式不正确，请重新输入"
            done
            
            while true; do
                read -p "请输入 DNS2 (例如: 1.1.1.1): " input_dns2
                validate_ip "$input_dns2" && break
                echo "❌ IP 格式不正确，请重新输入"
            done
            
            set_dns "$input_dns1" "$input_dns2"
            ;;
        2)
            echo ""
            echo "当前 DNS 配置:"
            if [ -f "$RESOLV_FILE" ]; then
                grep "^nameserver" "$RESOLV_FILE" || echo "未找到 nameserver 配置"
            else
                echo "文件不存在: $RESOLV_FILE"
            fi
            echo ""
            echo "服务状态:"
            systemctl status fix_dns.service --no-pager -l | grep "Active:"
            ;;
        3)
            echo "退出程序"
            exit 0
            ;;
        *)
            echo "无效选项，请输入 1-3"
            ;;
    esac
done
