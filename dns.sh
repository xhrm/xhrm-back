#!/bin/bash

# root 检查
[ "$EUID" -ne 0 ] && echo "请使用 root 运行" && exit 1

# 环境检测
if systemctl is-active --quiet NetworkManager; then
  MODE="NM"
elif systemctl is-active --quiet network; then
  MODE="NETWORK"
else
  MODE="MANUAL"
fi

# 显示 DNS
show_dns() {
  echo "当前 DNS："
  grep "^nameserver" /etc/resolv.conf || echo "未配置"
  echo
}

# NetworkManager 模式
set_dns_nm() {
  read -p "请输入 DNS（空格分隔）: " DNS
  CONN=$(nmcli -t -f NAME,DEVICE con show --active | grep -v ":$" | head -n1 | cut -d: -f1)

  [ -z "$CONN" ] && echo "未检测到有效连接" && return

  nmcli con mod "$CONN" ipv4.ignore-auto-dns yes
  nmcli con mod "$CONN" ipv4.dns "$DNS"
  nmcli con up "$CONN" >/dev/null

  echo "DNS 修改完成（NetworkManager）"
}

# network 服务模式
set_dns_network() {
  read -p "请输入 DNS（空格分隔）: " DNS
  IFACE=$(ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v lo | head -n1)

  [ -z "$IFACE" ] && echo "未找到网卡配置文件" && return

  sed -i '/^DNS[0-9]=/d' "$IFACE"

  i=1
  for d in $DNS; do
    echo "DNS$i=$d" >> "$IFACE"
    i=$((i+1))
  done

  systemctl restart network
  echo "DNS 修改完成（network 服务）"
}

# 手动强制模式
set_dns_manual() {
  read -p "请输入 DNS（空格分隔）: " DNS

  chattr -i /etc/resolv.conf 2>/dev/null
  > /etc/resolv.conf

  for d in $DNS; do
    echo "nameserver $d" >> /etc/resolv.conf
  done

  chattr +i /etc/resolv.conf
  echo "DNS 已强制写入并锁定"
}

# 菜单
while true; do
  echo "=============================="
  echo "当前模式：$MODE"
  echo "1) 修改 DNS"
  echo "2) 显示当前 DNS"
  echo "3) 退出"
  echo "=============================="
  read -p "请选择: " CHOICE

  case "$CHOICE" in
    1)
      case "$MODE" in
        NM) set_dns_nm ;;
        NETWORK) set_dns_network ;;
        MANUAL) set_dns_manual ;;
      esac
      ;;
    2) show_dns ;;
    3) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
