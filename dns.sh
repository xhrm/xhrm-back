#!/bin/bash
# 一键修改/还原 DNS 脚本 - CentOS 7/8 完全智能版
# 实时生效 + 重启后保持 + 自动安装 nmcli + 所有活动连接
# 作者: ChatGPT

BACKUP_FILE="/tmp/dns_backup_all.txt"
RESOLV_BACKUP="/tmp/resolv_backup.conf"

# 自动检测系统类型
detect_package_manager() {
    if command -v yum &>/dev/null; then
        PM="yum"
    elif command -v dnf &>/dev/null; then
        PM="dnf"
    else
        echo "❌ 未检测到 yum 或 dnf，请手动安装 NetworkManager"
        PM=""
    fi
}

# 自动安装 NetworkManager
install_nmcli() {
    if ! command -v nmcli &>/dev/null; then
        echo "⚠️ 未检测到 nmcli，尝试安装 NetworkManager..."
        detect_package_manager
        if [ -n "$PM" ]; then
            sudo $PM install -y NetworkManager
            if [ $? -ne 0 ]; then
                echo "❌ 安装失败，将退回 /etc/resolv.conf 修改模式"
                HAS_NMCLI=0
            else
                echo "✅ NetworkManager 安装完成"
                HAS_NMCLI=1
            fi
        else
            HAS_NMCLI=0
        fi
    else
        HAS_NMCLI=1
    fi
}

# 获取所有活动连接名称（nmcli 可用时）
get_active_connections() {
    nmcli -t -f NAME con show --active
}

# 备份 DNS
backup_dns() {
    if [ $HAS_NMCLI -eq 1 ]; then
        get_active_connections | while read -r con; do
            nmcli -g ipv4.dns con show "$con"
        done > "$BACKUP_FILE"
        echo "✅ 已备份所有活动连接 DNS 到 $BACKUP_FILE"
    else
        cp /etc/resolv.conf "$RESOLV_BACKUP"
        echo "✅ 已备份 /etc/resolv.conf 到 $RESOLV_BACKUP"
    fi
}

# 修改 DNS
set_dns() {
    echo "请输入要设置的 DNS 服务器地址（空格分隔，例如：223.5.5.5 1.1.1.1）："
    read -r dns_input
    if [ -z "$dns_input" ]; then
        echo "❌ 未输入 DNS，退出。"
        exit 1
    fi

    backup_dns

    if [ $HAS_NMCLI -eq 1 ]; then
        get_active_connections | while read -r con; do
            nmcli con mod "$con" ipv4.ignore-auto-dns yes
            nmcli con mod "$con" ipv4.dns "$dns_input"
            nmcli con up "$con" &>/dev/null
        done
        echo "✅ DNS 已通过 nmcli 修改为: $dns_input"
        nmcli dev show | grep DNS
    else
        chattr -i /etc/resolv.conf &>/dev/null
        > /etc/resolv.conf
        for dns in $dns_input; do
            echo "nameserver $dns" >> /etc/resolv.conf
        done
        chattr +i /etc/resolv.conf
        echo "✅ DNS 已通过 /etc/resolv.conf 修改为: $dns_input"
        cat /etc/resolv.conf
    fi
}

# 还原 DNS
restore_dns() {
    if [ $HAS_NMCLI -eq 1 ]; then
        if [ ! -f "$BACKUP_FILE" ]; then
            echo "❌ 未找到备份文件，无法还原。请先修改一次 DNS 才能恢复。"
            exit 1
        fi
        mapfile -t dns_lines < "$BACKUP_FILE"
        connections=($(get_active_connections))
        for i in "${!connections[@]}"; do
            old_dns="${dns_lines[$i]}"
            con="${connections[$i]}"
            if [ -z "$old_dns" ]; then
                nmcli con mod "$con" ipv4.ignore-auto-dns no
                nmcli con mod "$con" ipv4.dns ""
            else
                nmcli con mod "$con" ipv4.ignore-auto-dns yes
                nmcli con mod "$con" ipv4.dns "$old_dns"
            fi
            nmcli con up "$con" &>/dev/null
        done
        echo "✅ DNS 已成功还原"
        nmcli dev show | grep DNS
    else
        if [ ! -f "$RESOLV_BACKUP" ]; then
            echo "❌ 未找到 /etc/resolv.conf 备份，无法还原。"
            exit 1
        fi
        chattr -i /etc/resolv.conf &>/dev/null
        cp "$RESOLV_BACKUP" /etc/resolv.conf
        echo "✅ DNS 已通过 /etc/resolv.conf 还原"
        cat /etc/resolv.conf
    fi
}

# 初始化
install_nmcli

# 主菜单循环
while true; do
    echo "===== CentOS7/8 DNS 管理工具（智能增强版）====="
    echo "1. 修改 DNS"
    echo "2. 还原 DNS"
    echo "0. 退出"
    read -rp "请输入选项: " choice

    case $choice in
        1)
            set_dns
            ;;
        2)
            restore_dns
            ;;
        0)
            echo "已退出"
            exit 0
            ;;
        *)
            echo "❌ 无效选项，请重新输入"
            ;;
    esac
    echo ""
done
