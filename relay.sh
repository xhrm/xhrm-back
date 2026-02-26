#!/bin/bash

CONFIG="/etc/nginx/stream.d/trojan.conf"

check_root(){
    if [ "$EUID" -ne 0 ]; then
        echo "请使用 root 运行"
        exit 1
    fi
}

detect_system(){
    if [ -f /etc/redhat-release ]; then
        release=$(cat /etc/redhat-release)
        if [[ $release =~ "CentOS" ]]; then
            echo "检测到 CentOS 系统"
        else
            echo "仅支持 CentOS7/8"
            exit 1
        fi
    else
        echo "系统不支持"
        exit 1
    fi
}

install_dep(){
    echo "检测 Nginx..."
    if ! command -v nginx >/dev/null 2>&1; then
        echo "安装依赖..."
        yum install -y epel-release
        yum install -y nginx
    fi
    mkdir -p /etc/nginx/stream.d
    if ! grep -q "stream {" /etc/nginx/nginx.conf; then
cat >> /etc/nginx/nginx.conf <<EOF

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
    fi
    systemctl enable nginx
}

sys_opt(){
    grep -q tcp_fastopen /etc/sysctl.conf || cat >> /etc/sysctl.conf <<EOF

net.core.somaxconn=65535
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65000
EOF
    sysctl -p >/dev/null 2>&1
}

set_ip(){
    read -p "请输入目标 Trojan 服务器IP: " TARGET_IP
    cat > $CONFIG <<EOF
upstream trojan_backend {
    server ${TARGET_IP}:443;
}

server {
    listen 443 reuseport;
    proxy_pass trojan_backend;
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
}
EOF
    nginx -t && systemctl restart nginx
    echo "中转目标已修改为 ${TARGET_IP}:443，实时生效"
}

show_status(){
    echo "=============================="
    echo " Trojan-Go 中转当前状态"
    echo "=============================="

    # Nginx 状态
    systemctl is-active --quiet nginx && echo "Nginx: 运行中" || echo "Nginx: 未运行"

    # 当前后端 IP
    if [ -f "$CONFIG" ]; then
        BACKEND=$(grep "server" $CONFIG | grep -v "upstream" | awk -F ':' '{print $2":"$3}' | tr -d ' ')
        echo "当前中转目标: ${BACKEND}"
        # 测试 TCP 443 连接
        timeout 5 bash -c "cat < /dev/null > /dev/tcp/${BACKEND}"
        if [ $? -eq 0 ]; then
            echo "后端 TCP 443: 可连接"
        else
            echo "后端 TCP 443: 无法连接"
        fi
    else
        echo "当前中转目标未配置"
    fi
    echo "=============================="
}

install_all(){
    install_dep
    sys_opt
    set_ip
    systemctl restart nginx
    echo "安装完成，已设置开机自启"
}

check_root
detect_system
install_all
show_status

# 循环菜单只保留修改 IP
while true; do
    echo "=========================="
    echo " Trojan-Go 中转管理"
    echo "=========================="
    echo "1. 修改目标IP"
    echo "0. 退出"
    echo "=========================="
    read -p "请选择: " num
    case "$num" in
        1)
            set_ip
            show_status
            ;;
        0)
            exit 0
            ;;
        *)
            echo "输入错误"
            ;;
    esac
done
