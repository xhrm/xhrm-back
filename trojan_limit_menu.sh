#!/bin/bash
# ============================================================
# Trojan-Go 每个 IP 限速管理脚本（交互菜单版）
# 自动识别主网卡 + 限速开关/修改/查看
# 默认限速：上传/下载 20Mbps
# 适用于 CentOS / RHEL / AlmaLinux
# 作者：ChatGPT（自动生成）
# ============================================================

PORT="443"                        # Trojan-Go 端口
CONFIG_FILE="/etc/trojan_limit.conf"

# -------------------------------
# 自动检测主网卡
# -------------------------------
detect_iface() {
    ip route | grep default | awk '{print $5}' | head -n1
}

# -------------------------------
# 读取或设定限速配置
# -------------------------------
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        UP_RATE="20mbit"
        DOWN_RATE="20mbit"
    fi
}

save_config() {
    echo "UP_RATE=\"$UP_RATE\"" > $CONFIG_FILE
    echo "DOWN_RATE=\"$DOWN_RATE\"" >> $CONFIG_FILE
}

# -------------------------------
# 清除限速
# -------------------------------
clear_limit() {
    local iface=$1
    echo "🧹 清理旧规则..."
    tc qdisc del dev $iface root 2>/dev/null
    tc qdisc del dev $iface ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    iptables -t mangle -F
}

# -------------------------------
# 应用限速
# -------------------------------
apply_limit() {
    local iface=$1
    echo "⚙️ 应用限速：上传=$UP_RATE 下载=$DOWN_RATE 网卡=$iface 端口=$PORT"

    # 下载方向
    tc qdisc add dev $iface root handle 1: htb default 10
    tc class add dev $iface parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
    tc class add dev $iface parent 1:1 classid 1:10 htb rate $DOWN_RATE ceil $DOWN_RATE
    iptables -t mangle -A POSTROUTING -o $iface -p tcp --sport $PORT -j CONNMARK --set-mark 1
    tc filter add dev $iface parent 1: protocol ip handle 1 fw flowid 1:10

    # 上传方向
    modprobe ifb numifbs=1
    ip link set dev ifb0 up
    tc qdisc add dev $iface ingress
    tc filter add dev $iface parent ffff: protocol ip u32 match u32 0 0 \
        action mirred egress redirect dev ifb0

    tc qdisc add dev ifb0 root handle 2: htb default 20
    tc class add dev ifb0 parent 2: classid 2:1 htb rate 1000mbit ceil 1000mbit
    tc class add dev ifb0 parent 2:1 classid 2:20 htb rate $UP_RATE ceil $UP_RATE
    iptables -t mangle -A PREROUTING -i $iface -p tcp --dport $PORT -j CONNMARK --set-mark 2
    tc filter add dev ifb0 parent 2: protocol ip handle 2 fw flowid 2:20

    echo "✅ 已应用限速 (每个IP 上传:$UP_RATE 下载:$DOWN_RATE)"
}

# -------------------------------
# 查看状态
# -------------------------------
show_status() {
    local iface=$(detect_iface)
    echo "--------------------------------------------"
    echo "🌐 当前网卡: $iface"
    echo "📦 Trojan-Go 端口: $PORT"
    echo "⬆️ 上传限速: $UP_RATE"
    echo "⬇️ 下载限速: $DOWN_RATE"
    echo "--------------------------------------------"
    echo "🔍 tc $iface 限速情况:"
    tc -s class show dev $iface 2>/dev/null || echo "(无规则)"
    echo "--------------------------------------------"
    echo "🔍 tc ifb0 限速情况:"
    tc -s class show dev ifb0 2>/dev/null || echo "(无规则)"
    echo "--------------------------------------------"
}

# -------------------------------
# 修改限速
# -------------------------------
modify_limit() {
    read -p "请输入新的上传限速(Mbps): " up
    read -p "请输入新的下载限速(Mbps): " down
    if [[ -z "$up" || -z "$down" ]]; then
        echo "❌ 输入无效，已取消修改。"
        return
    fi
    UP_RATE="${up}mbit"
    DOWN_RATE="${down}mbit"
    save_config
    iface=$(detect_iface)
    clear_limit "$iface"
    apply_limit "$iface"
}

# -------------------------------
# 主菜单
# -------------------------------
menu() {
    load_config
    while true; do
        clear
        echo "============================================"
        echo "🚀 Trojan-Go 每个 IP 限速管理"
        echo "============================================"
        echo "1️⃣  开启限速"
        echo "2️⃣  关闭限速"
        echo "3️⃣  修改限速"
        echo "4️⃣  查看当前状态"
        echo "5️⃣  退出"
        echo "--------------------------------------------"
        echo "当前配置：上传=${UP_RATE} 下载=${DOWN_RATE}"
        echo "--------------------------------------------"
        read -p "请输入选项(1-5): " choice
        iface=$(detect_iface)
        case "$choice" in
            1)
                clear_limit "$iface"
                apply_limit "$iface"
                read -p "按回车键返回菜单..."
                ;;
            2)
                clear_limit "$iface"
                echo "🛑 限速已关闭"
                read -p "按回车键返回菜单..."
                ;;
            3)
                modify_limit
                read -p "按回车键返回菜单..."
                ;;
            4)
                show_status
                read -p "按回车键返回菜单..."
                ;;
            5)
                echo "👋 已退出"
                exit 0
                ;;
            *)
                echo "❌ 无效选项，请输入 1~5"
                sleep 1
                ;;
        esac
    done
}

menu
