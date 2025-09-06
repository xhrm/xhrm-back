#!/bin/bash
# 一键修改/还原 DNS 脚本 - 适用于 CentOS 7/8
# 作者: ChatGPT

BACKUP_FILE="/tmp/dns_backup.conf"

# 获取 CentOS 版本
get_os_version() {
    if [ -f /etc/redhat-release ]; then
        grep -oE "[0-9]+" /etc/redhat-release | head -1
    else
        echo "不支持的系统"
        exit 1
    fi
}

# 备份当前 DNS
backup_dns() {
    local con_name
    con_name=$(nmcli -t -f NAME con show --active | head -n 1)
    nmcli con show "$con_name" | grep ipv4.dns | awk '{print $2}' > "$BACKUP_FILE"
    echo "已备份当前 DNS 到 $BACKUP_FILE"
}

# 修改 DNS
set_dns() {
    echo "请输入要设置的 DNS 服务器地址（空格分隔，例: 223.5.5.5 1.1.1.1）："
    read -r dns_input
    if [ -z "$dns_input" ]; then
        echo "未输入，退出。"
        exit 1
    fi

    local version con_name
    version=$(get_os_version)
    con_name=$(nmcli -t -f NAME con show --active | head -n 1)

    # 修改前先备份
    backup_dns

    nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
    nmcli con mod "$con_name" ipv4.dns "$dns_input"
    nmcli con up "$con_name"

    echo "✅ DNS 已修改为: $dns_input"
}

# 还原 DNS
restore_dns() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "❌ 未找到备份文件，无法还原。请先修改一次 DNS 才能恢复。"
        exit 1
    fi

    local con_name old_dns
    con_name=$(nmcli -t -f NAME con show --active | head -n 1)
    old_dns=$(cat "$BACKUP_FILE")

    if [ -z "$old_dns" ]; then
        echo "原始 DNS 为空，恢复为自动获取。"
        nmcli con mod "$con_name" ipv4.ignore-auto-dns no
        nmcli con mod "$con_name" -ipv4.dns
    else
        echo "正在还原 DNS: $old_dns"
        nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
        nmcli con mod "$con_name" ipv4.dns "$old_dns"
    fi

    nmcli con up "$con_name"
    echo "✅ DNS 已成功还原为: $old_dns"
}

# 主菜单
echo "===== CentOS7/8 DNS 管理工具 ====="
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
        echo "无效选项"
        exit 1
        ;;
esac
