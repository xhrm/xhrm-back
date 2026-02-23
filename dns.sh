#!/bin/bash
# 文件名: fix_dns_menu.sh
# 功能: 菜单修改 DNS + 实时生效 + 开机自启 + 自动监控

# 检查 root
[ "$EUID" -ne 0 ] && echo "请使用 root 运行" && exit 1

RESOLV_FILE="/etc/resolv.conf"
SERVICE_FILE="/etc/systemd/system/fix_dns.service"
SCRIPT_FILE="/usr/local/bin/fix_dns_service.sh"

# 默认 DNS
DNS1="8.8.8.8"
DNS2="1.1.1.1"

# -------------------------
# 生成后台修复脚本
# -------------------------
cat > "$SCRIPT_FILE" <<'EOF'
#!/bin/bash
RESOLV_FILE="/etc/resolv.conf"
CONFIG_FILE="/etc/fix_dns_current.conf"

# 读取配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 修复 resolv.conf
fix_resolv_conf() {
    [ -L "$RESOLV_FILE" ] && rm -f "$RESOLV_FILE" && touch "$RESOLV_FILE"
    chattr -i "$RESOLV_FILE" 2>/dev/null
    echo -e "nameserver $DNS1\nnameserver $DNS2" > "$RESOLV_FILE"
    chattr +i "$RESOLV_FILE"
}

# NetworkManager 模式
set_dns_nm() {
    CONN=$(nmcli -t -f NAME,DEVICE con show --active | grep -v ":$" | head -n1 | cut -d: -f1)
    [ -n "$CONN" ] && nmcli con mod "$CONN" ipv4.ignore-auto-dns yes
    [ -n "$CONN" ] && nmcli con mod "$CONN" ipv4.dns "$DNS1 $DNS2"
    [ -n "$CONN" ] && nmcli con up "$CONN"
    fix_resolv_conf
}

# network 模式
set_dns_network() {
    IFACE=$(ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v lo | head -n1)
    [ -n "$IFACE" ] && sed -i '/^DNS[0-9]=/d' "$IFACE"
    [ -n "$IFACE" ] && echo "DNS1=$DNS1" >> "$IFACE"
    [ -n "$IFACE" ] && echo "DNS2=$DNS2" >> "$IFACE"
    [ -n "$IFACE" ] && systemctl restart network
    fix_resolv_conf
}

# 手动模式
set_dns_manual() { fix_resolv_conf; }

# 检测模式
if systemctl is-active --quiet NetworkManager; then
    MODE="NM"
elif systemctl is-active --quiet network; then
    MODE="NETWORK"
else
    MODE="MANUAL"
fi

# 初始修复
case "$MODE" in
    NM) set_dns_nm ;;
    NETWORK) set_dns_network ;;
    MANUAL) set_dns_manual ;;
esac

# 持续监控 DNS
while true; do
    sleep 60
    if ! grep -q "$DNS1" "$RESOLV_FILE" || ! grep -q "$DNS2" "$RESOLV_FILE"; then
        echo "$(date '+%F %T') 检测到 DNS 被覆盖，正在修复..."
        case "$MODE" in
            NM) set_dns_nm ;;
            NETWORK) set_dns_network ;;
            MANUAL) set_dns_manual ;;
        esac
    fi
done
EOF

chmod +x "$SCRIPT_FILE"

# -------------------------
# 创建 systemd 服务
# -------------------------
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=自动修复 DNS 劫持并锁定
After=network.target NetworkManager.service

[Service]
Type=simple
ExecStart=$SCRIPT_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fix_dns.service
systemctl start fix_dns.service

# -------------------------
# 菜单
# -------------------------
CONFIG_FILE="/etc/fix_dns_current.conf"
touch "$CONFIG_FILE"

while true; do
    echo "=============================="
    echo "1) 修改 DNS（手动输入）"
    echo "2) 显示当前 DNS"
    echo "3) 退出"
    echo "=============================="
    read -p "请选择: " CHOICE

    case "$CHOICE" in
        1)
            read -p "请输入 DNS1: " DNS1
            read -p "请输入 DNS2: " DNS2
            # 保存配置
            echo "DNS1=$DNS1" > "$CONFIG_FILE"
            echo "DNS2=$DNS2" >> "$CONFIG_FILE"

            # 立即生效
            if systemctl is-active --quiet NetworkManager; then
                CONN=$(nmcli -t -f NAME,DEVICE con show --active | grep -v ":$" | head -n1 | cut -d: -f1)
                [ -n "$CONN" ] && nmcli con mod "$CONN" ipv4.ignore-auto-dns yes
                [ -n "$CONN" ] && nmcli con mod "$CONN" ipv4.dns "$DNS1 $DNS2"
                [ -n "$CONN" ] && nmcli con up "$CONN"
            elif systemctl is-active --quiet network; then
                IFACE=$(ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v lo | head -n1)
                [ -n "$IFACE" ] && sed -i '/^DNS[0-9]=/d' "$IFACE"
                [ -n "$IFACE" ] && echo "DNS1=$DNS1" >> "$IFACE"
                [ -n "$IFACE" ] && echo "DNS2=$DNS2" >> "$IFACE"
                [ -n "$IFACE" ] && systemctl restart network
            fi
            # 手动模式或通用锁定
            chattr -i /etc/resolv.conf 2>/dev/null
            echo -e "nameserver $DNS1\nnameserver $DNS2" > /etc/resolv.conf
            chattr +i /etc/resolv.conf
            echo "✅ DNS 已修改并生效"
            ;;
        2)
            grep "^nameserver" /etc/resolv.conf || echo "未配置"
            ;;
        3)
            exit 0
            ;;
        *)
            echo "无效选项"
            ;;
    esac
done
