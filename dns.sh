#!/bin/bash
# 一键修改/还原 DNS 脚本 - CentOS 7/8
# 实时生效 + 重启后持久生效
# 作者: ChatGPT

BACKUP_FILE="/tmp/dns_backup.conf"

# 检查 nmcli 是否安装
if ! command -v nmcli &>/dev/null; then
    echo "❌ 未检测到 nmcli，请先安装 NetworkManager"
    exit 1
fi

# 获取活动连接名称
get_active_connection() {
    local con_name
    con_name=$(nmcli -t -f NAME con show --active | head -n 1)
    if [ -z "$con_name" ]; then
        echo "❌ 未检测到活动网络连接"
        exit 1
    fi
    echo "$con_name"
}

# 备份当前 DNS
backup_dns() {
    local con_name
    con_name=$(get_active_connection)
    nmcli -g ipv4.dns con show "$con_name" > "$BACKUP_FILE"
    echo "✅ 已备份当前 DNS 到 $BACKUP_FILE"
}

# 修改 DNS
set_dns() {
    echo "请输入要设置的 DNS 服务器地址（空格分隔，例: 223.5.5.5 1.1.1.1）："
    read -r dns_input
    if [ -z "$dns_input" ]; then
        echo "❌ 未输入 DNS，退出。"
        exit 1
    fi

    local con_name
    con_name=$(get_active_connection)
    backup_dns

    # 修改 DNS 并禁止自动获取
    nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
    nmcli con mod "$con_name" ipv4.dns "$dns_input"

    # 立即生效
    nmcli con up "$con_name" &>/dev/null

    echo "✅ DNS 已修改为: $dns_input"
    echo "当前生效 DNS:"
    nmcli dev show | grep DNS
}

# 还原 DNS
restore_dns() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "❌ 未找到备份文件，无法还原。请先修改一次 DNS 才能恢复。"
        exit 1
    fi

    local con_name old_dns
    con_name=$(get_active_connection)
    old_dns=$(cat "$BACKUP_FILE")

    if [ -z "$old_dns" ]; then
        echo "原始 DNS 为空，恢复为自动获取"
        nmcli con mod "$con_name" ipv4.ignore-auto-dns no
        nmcli con mod "$con_name" ipv4.dns ""
    else
        echo "正在还原 DNS: $old_dns"
        nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
        nmcli con mod "$con_name" ipv4.dns "$old_dns"
    fi

    # 立即生效
    nmcli con up "$con_name" &>/dev/null

    echo "✅ DNS 已成功还原为: $old_dns"
    echo "当前生效 DNS:"
    nmcli dev show | grep DNS
}

# 主菜单循环
while true; do
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
            echo "❌ 无效选项，请重新输入"
            ;;
    esac
    echo ""
done
