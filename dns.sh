#!/bin/bash
# CentOS 7/8 DNS 管理工具（稳定修复版）

BACKUP_FILE="/tmp/nm_dns_backup.txt"
RESOLV_BACKUP="/tmp/resolv_backup.conf"

set -e

detect_package_manager() {
    if command -v yum &>/dev/null; then
        PM="yum"
    elif command -v dnf &>/dev/null; then
        PM="dnf"
    else
        PM=""
    fi
}

install_nmcli() {
    if command -v nmcli &>/dev/null; then
        HAS_NMCLI=1
        return
    fi

    detect_package_manager
    if [ -z "$PM" ]; then
        HAS_NMCLI=0
        return
    fi

    sudo $PM install -y NetworkManager
    systemctl enable --now NetworkManager
    HAS_NMCLI=1
}

get_all_connections() {
    nmcli -t -f NAME con show
}

backup_dns() {
    if [ "$HAS_NMCLI" -eq 1 ]; then
        : > "$BACKUP_FILE"
        mapfile -t connections < <(get_all_connections)
        for con in "${connections[@]}"; do
            dns=$(nmcli -g ipv4.dns con show "$con")
            echo "$con|$dns" >> "$BACKUP_FILE"
        done
        echo "✅ DNS 已备份到 $BACKUP_FILE"
    else
        cp /etc/resolv.conf "$RESOLV_BACKUP"
        echo "✅ /etc/resolv.conf 已备份"
    fi
}

set_dns() {
    read -rp "请输入 DNS（空格分隔）： " dns_input
    [ -z "$dns_input" ] && echo "❌ DNS 不能为空" && exit 1

    backup_dns

    if [ "$HAS_NMCLI" -eq 1 ]; then
        mapfile -t connections < <(get_all_connections)
        for con in "${connections[@]}"; do
            nmcli con mod "$con" ipv4.ignore-auto-dns yes
            nmcli con mod "$con" ipv4.dns "$dns_input"
        done
        echo "✅ DNS 设置完成（重连后生效）"
    else
        cp /etc/resolv.conf "$RESOLV_BACKUP"
        > /etc/resolv.conf
        for dns in $dns_input; do
            echo "nameserver $dns" >> /etc/resolv.conf
        done
        echo "✅ resolv.conf 已修改"
    fi
}

restore_dns() {
    if [ "$HAS_NMCLI" -eq 1 ]; then
        [ ! -f "$BACKUP_FILE" ] && echo "❌ 未找到备份" && exit 1

        while IFS="|" read -r con dns; do
            if [ -z "$dns" ]; then
                nmcli con mod "$con" ipv4.ignore-auto-dns no
                nmcli con mod "$con" ipv4.dns ""
            else
                nmcli con mod "$con" ipv4.ignore-auto-dns yes
                nmcli con mod "$con" ipv4.dns "$dns"
            fi
        done < "$BACKUP_FILE"

        echo "✅ DNS 已准确还原（按连接名）"
    else
        [ ! -f "$RESOLV_BACKUP" ] && echo "❌ 无备份" && exit 1
        cp "$RESOLV_BACKUP" /etc/resolv.conf
        echo "✅ resolv.conf 已还原"
    fi
}

install_nmcli

while true; do
    echo "====== DNS 管理工具（修复稳定版）======"
    echo "1. 修改 DNS"
    echo "2. 还原 DNS"
    echo "0. 退出"
    read -rp "选择: " choice

    case "$choice" in
        1) set_dns ;;
        2) restore_dns ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项" ;;
    esac
    echo
done
