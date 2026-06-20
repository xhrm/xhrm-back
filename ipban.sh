#!/bin/bash

ACTION=$1
IP=$2

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行"
  exit 1
fi

# 检测防火墙类型
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    FW="firewalld"
elif command -v iptables >/dev/null 2>&1; then
    FW="iptables"
else
    echo "未检测到 iptables 或 firewalld"
    exit 1
fi

ban_ip() {
    if [[ -z "$IP" ]]; then
        echo "请提供 IP"
        exit 1
    fi

    if [[ "$FW" == "firewalld" ]]; then
        firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$IP' reject"
        firewall-cmd --reload
        echo "已封禁 $IP (firewalld)"
    else
        iptables -I INPUT -s "$IP" -j DROP
        echo "已封禁 $IP (iptables)"
    fi
}

unban_ip() {
    if [[ -z "$IP" ]]; then
        echo "请提供 IP"
        exit 1
    fi

    if [[ "$FW" == "firewalld" ]]; then
        firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='$IP' reject"
        firewall-cmd --reload
        echo "已解封 $IP (firewalld)"
    else
        iptables -D INPUT -s "$IP" -j DROP 2>/dev/null
        echo "已解封 $IP (iptables)"
    fi
}

list_rules() {
    if [[ "$FW" == "firewalld" ]]; then
        firewall-cmd --list-rich-rules
    else
        iptables -L INPUT -n --line-numbers
    fi
}

case "$ACTION" in
    ban)
        ban_ip
        ;;
    unban)
        unban_ip
        ;;
    list)
        list_rules
        ;;
    *)
        echo "用法:"
        echo "  $0 ban <IP>    封禁IP"
        echo "  $0 unban <IP>  解封IP"
        echo "  $0 list        查看规则"
        exit 1
        ;;
esac