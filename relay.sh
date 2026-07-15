#!/bin/bash

CONFIG="/etc/nginx/stream.d/forward.conf"
NGINX_CONF="/etc/nginx/nginx.conf"
SYSCTL_CONF="/etc/sysctl.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

check_root(){
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 运行${NC}"
        exit 1
    fi
}

detect_system(){
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        VERSION=$(rpm -E %{rhel})
    else
        echo -e "${RED}不支持的系统${NC}"
        exit 1
    fi
    
    case $OS in
        centos|rhel)
            PKG_MANAGER="yum"
            ;;
        debian|ubuntu)
            PKG_MANAGER="apt-get"
            ;;
        *)
            echo -e "${RED}不支持的系统: $OS${NC}"
            exit 1
            ;;
    esac
}

install_dep(){
    echo -e "${BLUE}检测依赖...${NC}"
    
    case $PKG_MANAGER in
        yum)
            if ! command -v nginx >/dev/null 2>&1; then
                echo -e "${YELLOW}安装 EPEL 源和 Nginx...${NC}"
                yum install -y epel-release
                yum install -y nginx
            fi
            ;;
        apt-get)
            apt-get update
            if ! command -v nginx >/dev/null 2>&1; then
                echo -e "${YELLOW}安装 Nginx...${NC}"
                apt-get install -y nginx
            fi
            ;;
    esac
    
    mkdir -p /etc/nginx/stream.d
    
    if ! grep -q "stream {" $NGINX_CONF; then
        sed -i '$a\\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}' $NGINX_CONF
    fi
    
    if ! id nginx >/dev/null 2>&1; then
        useradd -r -s /sbin/nologin nginx
    fi
    
    systemctl enable nginx
    echo -e "${GREEN}依赖安装完成${NC}"
}

sys_opt(){
    echo -e "${BLUE}应用系统优化...${NC}"
    
    if [ ! -f ${SYSCTL_CONF}.bak ]; then
        cp $SYSCTL_CONF ${SYSCTL_CONF}.bak
    fi
    
    cat > /etc/sysctl.d/99-forward-optimize.conf <<EOF
# TCP 优化
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65535

# TCP 连接优化
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_tw_buckets = 65535
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
EOF

    sysctl -p /etc/sysctl.d/99-forward-optimize.conf >/dev/null 2>&1
    
    CPU_CORES=$(nproc)
    
    if [ -f $NGINX_CONF ]; then
        cp $NGINX_CONF ${NGINX_CONF}.bak.$(date +%Y%m%d)
        
        if grep -q "worker_processes" $NGINX_CONF; then
            sed -i "s/worker_processes.*;/worker_processes $CPU_CORES;/" $NGINX_CONF
        else
            sed -i "1iworker_processes $CPU_CORES;" $NGINX_CONF
        fi
        
        if grep -q "worker_connections" $NGINX_CONF; then
            sed -i "s/worker_connections.*;/worker_connections 65535;/" $NGINX_CONF
        fi
        
        if ! grep -q "worker_rlimit_nofile" $NGINX_CONF; then
            sed -i '1iworker_rlimit_nofile 65535;' $NGINX_CONF
        fi
    fi
    
    echo -e "${GREEN}系统优化完成${NC}"
}

set_ip(){
    if [ -f "$CONFIG" ]; then
        CURRENT_IP=$(grep "server" $CONFIG | grep -v "upstream" | awk '{print $2}' | cut -d: -f1)
        echo -e "${YELLOW}当前目标 IP: ${CURRENT_IP}${NC}"
    fi
    
    read -p "请输入目标服务器IP: " TARGET_IP
    if [ -z "$TARGET_IP" ]; then
        echo -e "${RED}IP 不能为空${NC}"
        return 1
    fi
    
    if ! [[ $TARGET_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}IP 格式不正确${NC}"
        return 1
    fi
    
    cat > $CONFIG <<EOF
upstream backend {
    server ${TARGET_IP}:443 max_fails=3 fail_timeout=10s;
    keepalive 64;
    keepalive_requests 1000;
    keepalive_timeout 60s;
}

server {
    listen 443 reuseport fastopen=256;
    proxy_pass backend;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
    proxy_buffer_size 16k;
    proxy_socket_keepalive on;
}
EOF

    nginx -t && systemctl restart nginx
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}中转目标已修改为 ${TARGET_IP}:443，实时生效${NC}"
    else
        echo -e "${RED}Nginx 配置测试失败，请检查配置${NC}"
        return 1
    fi
}

install_all(){
    echo -e "${BLUE}开始安装 TCP 中转服务...${NC}"
    install_dep
    sys_opt
    echo -e "${GREEN}环境准备完成，请设置中转目标IP${NC}"
}

show_status(){
    echo
    echo -e "${BLUE}==============================${NC}"
    echo -e "${BLUE}       TCP 中转当前状态       ${NC}"
    echo -e "${BLUE}==============================${NC}"
    
    if systemctl is-active --quiet nginx; then
        echo -e "Nginx: ${GREEN}运行中${NC}"
    else
        echo -e "Nginx: ${RED}未运行${NC}"
    fi
    
    if [ -f "$CONFIG" ]; then
        BACKEND=$(grep "server" $CONFIG | grep -v "upstream" | awk '{print $2}' | tr -d ';')
        echo -e "中转目标: ${GREEN}${BACKEND}${NC}"
        
        BACKEND_IP=$(echo $BACKEND | cut -d: -f1)
        BACKEND_PORT=$(echo $BACKEND | cut -d: -f2)
        
        if timeout 3 bash -c "echo >/dev/tcp/${BACKEND_IP}/${BACKEND_PORT}" 2>/dev/null; then
            echo -e "后端连接: ${GREEN}可达${NC}"
        else
            echo -e "后端连接: ${RED}不可达${NC}"
        fi
        
        if systemctl is-active --quiet nginx; then
            CONNECTIONS=$(ss -tn state established '( sport = :443 )' | wc -l)
            echo -e "当前连接: ${GREEN}$((CONNECTIONS-1))${NC}"
        fi
    else
        echo -e "中转配置: ${YELLOW}未安装${NC}"
    fi
    echo -e "${BLUE}==============================${NC}"
    echo
}

show_menu(){
    while true; do
        show_status
        echo -e "${BLUE}==============================${NC}"
        echo -e "1. ${GREEN}安装/重新安装${NC}"
        echo -e "2. ${GREEN}修改目标IP${NC}"
        echo -e "0. ${RED}退出${NC}"
        echo -e "${BLUE}==============================${NC}"
        read -p "请选择操作 [0-2]: " num
        case "$num" in
            1)
                install_all
                set_ip
                ;;
            2)
                set_ip
                ;;
            0)
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}输入错误，请重新选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 主程序
check_root
detect_system

if [ ! -f "$CONFIG" ]; then
    show_status
    echo -e "${YELLOW}检测到尚未安装，是否立即安装？${NC}"
    read -p "是否安装? [Y/n]: " install_choice
    if [[ ! $install_choice =~ ^[Nn] ]]; then
        install_all
        set_ip
    fi
fi

show_menu
