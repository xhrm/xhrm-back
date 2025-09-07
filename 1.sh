#!/bin/bash
# ===========================================
# A 机器状态检查脚本
# 检查 dnsmasq / sniproxy / stunnel / iptables 是否正常
# ===========================================

set -euo pipefail

A_DNS="127.0.0.1"
TEST_DOMAIN="netflix.com"
HTTPS_PORT=8443

echo "==================== A 机器状态检查 ===================="

# 1. 检查 dnsmasq
echo -n "[1/4] 检查 dnsmasq 服务... "
if systemctl is-active --quiet dnsmasq; then
    echo "运行中 ✅"
else
    echo "未运行 ❌"
fi

# 2. 检查 53 端口占用
echo -n "[2/4] 检查 53 端口监听... "
if ss -ltnp | grep -q ":53.*dnsmasq"; then
    echo "dnsmasq 占用 ✅"
else
    echo "53端口未监听或被占用 ❌"
fi

# 3. 测试本地 DNS 解析
echo -n "[3/4] 测试 DNS 解析 $TEST_DOMAIN ... "
DNS_RESULT=$(dig @$A_DNS $TEST_DOMAIN +short)
if [ -n "$DNS_RESULT" ]; then
    echo "成功 ✅ 解析 IP: $DNS_RESULT"
else
    echo "失败 ❌"
fi

# 4. 检查 sniproxy 和 stunnel
echo -n "[4/4] 检查 sniproxy 服务... "
if systemctl is-active --quiet sniproxy; then
    echo "运行中 ✅"
else
    echo "未运行 ❌"
fi

echo -n "[4/4] 检查 stunnel 服务... "
if systemctl is-active --quiet stunnel4; then
    echo "运行中 ✅"
else
    echo "未运行 ❌"
fi

# 5. 检查 iptables HTTPS 重定向
echo -n "[5/5] 检查 iptables HTTPS 转发 (443 -> $HTTPS_PORT)... "
if iptables -t nat -L PREROUTING -n -v | grep -q "tcp dpt:443.*redir ports $HTTPS_PORT"; then
    echo "规则存在 ✅"
else
    echo "未生效 ❌"
fi

echo "========================================================"
echo "提示："
echo " - 如果 DNS 解析失败，请检查 dnsmasq 和 systemd-resolved 占用"
echo " - 如果 HTTPS 转发失败，请检查 sniproxy、stunnel 和 iptables"
echo " - 可通过 'systemctl status 服务名' 查看详细日志"
echo "========================================================"
