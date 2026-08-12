#!/bin/bash

CONFIG="/etc/nginx/stream.d/forward.conf"
NGINX_CONF="/etc/nginx/nginx.conf"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

check_root(){
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用root运行${NC}"
        exit 1
    fi
}

detect_system(){
    if [ ! -f /etc/os-release ]; then
        echo "无法识别系统"
        exit 1
    fi

    source /etc/os-release
    OS=$ID

    case "$OS" in
        debian|ubuntu)
            PM="apt"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            PM="yum"
            ;;
        *)
            echo "不支持系统: $OS"
            exit 1
            ;;
    esac
}

install_nginx(){
    if command -v nginx >/dev/null 2>&1; then
        echo -e "${GREEN}nginx已安装${NC}"
        return
    fi

    echo -e "${BLUE}安装nginx${NC}"

    case "$PM" in
        apt)
            apt update
            apt install -y nginx
            ;;
        yum)
            cat >/etc/yum.repos.d/nginx.repo <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
EOF
            yum install -y nginx
            ;;
    esac
}

install_stream(){
    echo -e "${BLUE}检查stream模块${NC}"

    # Debian / Ubuntu
    if [ "$PM" = "apt" ]; then
        if [ ! -f /etc/nginx/modules-enabled/50-mod-stream.conf ]; then
            echo -e "${YELLOW}安装stream模块${NC}"
            apt update
            apt install -y libnginx-mod-stream
        fi
        echo -e "${GREEN}Debian stream正常${NC}"
        return
    fi

    # CentOS
    if nginx -V 2>&1 | grep -q -- "--with-stream"; then
        echo -e "${GREEN}nginx内置stream${NC}"
        return
    fi

    MODULE=""

    if [ -f /usr/lib64/nginx/modules/ngx_stream_module.so ]; then
        MODULE="/usr/lib64/nginx/modules/ngx_stream_module.so"
    fi

    if [ -z "$MODULE" ] && [ -f /usr/lib/nginx/modules/ngx_stream_module.so ]; then
        MODULE="/usr/lib/nginx/modules/ngx_stream_module.so"
    fi

    if [ -z "$MODULE" ]; then
        yum install -y nginx-mod-stream
        if [ -f /usr/lib64/nginx/modules/ngx_stream_module.so ]; then
            MODULE="/usr/lib64/nginx/modules/ngx_stream_module.so"
        fi
    fi

    if [ -z "$MODULE" ]; then
        echo -e "${RED}stream模块安装失败${NC}"
        exit 1
    fi

    if ! grep -q "ngx_stream_module.so" "$NGINX_CONF"; then
        cp "$NGINX_CONF" "${NGINX_CONF}.bak"
        sed -i '1iload_module modules/ngx_stream_module.so;' "$NGINX_CONF"
    fi

    echo -e "${GREEN}CentOS stream正常${NC}"
}

config_stream(){
    mkdir -p /etc/nginx/stream.d

    if ! grep -q "include /etc/nginx/stream.d/*.conf" "$NGINX_CONF"; then
        cat >> "$NGINX_CONF" <<EOF

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
    fi
}

set_forward(){
    read -p "请输入目标服务器IP: " IP

    if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${RED}IP格式错误${NC}"
        return
    fi

    cat > "${CONFIG}.tmp" <<EOF
upstream forward_backend {
    server ${IP}:443;
}

server {
    listen 443 reuseport fastopen=1024;
    proxy_pass forward_backend;
    proxy_connect_timeout 10s;
    proxy_timeout 24h;
    proxy_socket_keepalive on;
}
EOF

    mv "${CONFIG}.tmp" "$CONFIG"
    echo -e "${BLUE}测试配置${NC}"

    if nginx -t; then
        systemctl enable nginx >/dev/null 2>&1
        systemctl restart nginx
        if systemctl is-active nginx >/dev/null 2>&1; then
            echo
            echo -e "${GREEN}部署成功${NC}"
            echo "本机443 ---> ${IP}:443"
        else
            echo -e "${RED}nginx启动失败${NC}"
        fi
    else
        echo -e "${RED}nginx配置错误${NC}"
        nginx -t
    fi
}

show_status(){
    echo
    echo "==========状态=========="

    if systemctl is-active nginx >/dev/null 2>&1; then
        echo -e "nginx: ${GREEN}运行中${NC}"
    else
        echo -e "nginx: ${RED}停止${NC}"
    fi

    if [ -f "$CONFIG" ]; then
        echo "转发目标:"
        grep "server .*:443" "$CONFIG"
    fi

    echo "========================"
}

main(){
    check_root
    detect_system
    install_nginx
    install_stream
    config_stream

    while true
    do
        echo
        echo "1. 设置转发"
        echo "2. 查看状态"
        echo "0. 退出"
        read -p "请选择: " CH

        case "$CH" in
            1)
                set_forward
                ;;
            2)
                show_status
                ;;
            0)
                exit
                ;;
            *)
                echo "输入错误"
                ;;
        esac
    done
}

main
