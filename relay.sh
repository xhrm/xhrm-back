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
        VERSION=$(rpm -E %{rhel} 2>/dev/null || echo "7")
    else
        echo -e "${RED}不支持的系统${NC}"
        exit 1
    fi
    
    case $OS in
        centos|rhel|fedora)
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

# 检查 nginx 是否支持 stream 模块
check_stream_module(){
    if command -v nginx >/dev/null 2>&1; then
        if nginx -V 2>&1 | grep -q "with-stream"; then
            return 0
        fi
    fi
    return 1
}

install_nginx_with_stream(){
    echo -e "${BLUE}安装支持 stream 模块的 Nginx...${NC}"
    
    case $PKG_MANAGER in
        yum)
            cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
            
            yum install -y epel-release 2>/dev/null
            yum install -y nginx
            
            if ! check_stream_module; then
                yum install -y nginx-mod-stream 2>/dev/null
            fi
            ;;
            
        apt-get)
            apt-get update
            apt-get install -y curl gnupg2 ca-certificates lsb-release
            
            if [ "$OS" = "ubuntu" ]; then
                echo "deb http://nginx.org/packages/ubuntu/ $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
            else
                echo "deb http://nginx.org/packages/debian/ $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
            fi
            
            curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -
            apt-get update
            apt-get install -y nginx
            
            if ! check_stream_module; then
                apt-get remove -y nginx 2>/dev/null
                apt-get install -y nginx-extras 2>/dev/null || apt-get install -y nginx-full 2>/dev/null
            fi
            ;;
    esac
    
    if ! check_stream_module; then
        echo -e "${RED}Nginx stream 模块安装失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Nginx stream 模块安装成功${NC}"
}

install_dep(){
    echo -e "${BLUE}检测依赖...${NC}"
    
    if command -v nginx >/dev/null 2>&1; then
        if check_stream_module; then
            echo -e "${GREEN}Nginx 已支持 stream 模块${NC}"
        else
            echo -e "${YELLOW}Nginx 不支持 stream 模块，重新安装...${NC}"
            systemctl stop nginx 2>/dev/null
            case $PKG_MANAGER in
                yum) yum remove -y nginx nginx-* 2>/dev/null ;;
                apt-get) apt-get remove -y nginx nginx-common nginx-full nginx-extras 2>/dev/null ;;
            esac
            install_nginx_with_stream
        fi
    else
        install_nginx_with_stream
    fi
    
    # 安装必要工具
    case $PKG_MANAGER in
        yum) yum install -y net-tools iproute 2>/dev/null ;;
        apt-get) apt-get install -y net-tools iproute2 2>/dev/null ;;
    esac
    
    # 创建 stream 配置目录
    mkdir -p /etc/nginx/stream.d
    
    # 添加 stream 配置到 nginx.conf
    if [ -f $NGINX_CONF ]; then
        if ! grep -q "include /etc/nginx/stream.d/\*.conf" $NGINX_CONF; then
            cp $NGINX_CONF ${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)
            
            if ! grep -q "^stream {" $NGINX_CONF; then
                if grep -q "^http {" $NGINX_CONF; then
                    HTTP_END_LINE=$(grep -n "^}" $NGINX_CONF | tail -1 | cut -d: -f1)
                    if [ -n "$HTTP_END_LINE" ]; then
                        sed -i "${HTTP_END_LINE}a\\\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}" $NGINX_CONF
                    else
                        cat >> $NGINX_CONF <<'EOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
                    fi
                else
                    cat >> $NGINX_CONF <<'EOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
                fi
            fi
        fi
    fi
    
    # 创建 nginx 用户
    if ! id nginx >/dev/null 2>&1; then
        useradd -r -s /sbin/nologin nginx 2>/dev/null || \
        useradd -r -s /usr/sbin/nologin nginx 2>/dev/null || \
        adduser --system --no-create-home --shell /usr/sbin/nologin nginx 2>/dev/null
    fi
    
    chown -R root:root /etc/nginx 2>/dev/null
    chmod 755 /etc/nginx/stream.d 2>/dev/null
    
    systemctl enable nginx >/dev/null 2>&1
    echo -e "${GREEN}依赖安装完成${NC}"
}

sys_opt(){
    echo -e "${BLUE}应用系统优化...${NC}"
    
    if [ ! -f ${SYSCTL_CONF}.bak ]; then
        cp $SYSCTL_CONF ${SYSCTL_CONF}.bak 2>/dev/null || true
    fi
    
    cat > /etc/sysctl.d/99-forward-optimize.conf <<'EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65535
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
fs.file-max = 6553560
fs.nr_open = 6553560
EOF

    sysctl -p /etc/sysctl.d/99-forward-optimize.conf >/dev/null 2>&1
    
    CPU_CORES=$(nproc)
    
    if [ -f $NGINX_CONF ]; then
        cp $NGINX_CONF ${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)
        
        if grep -q "worker_processes" $NGINX_CONF; then
            sed -i "s/worker_processes\s\+.*;/worker_processes $CPU_CORES;/" $NGINX_CONF
        else
            sed -i "1iworker_processes $CPU_CORES;" $NGINX_CONF
        fi
        
        if ! grep -q "worker_rlimit_nofile" $NGINX_CONF; then
            sed -i "1iworker_rlimit_nofile 65535;" $NGINX_CONF
        fi
        
        if grep -q "worker_connections" $NGINX_CONF; then
            sed -i "s/worker_connections\s\+[0-9]\+;/worker_connections 65535;/" $NGINX_CONF
        else
            sed -i '/events {/a\    worker_connections 65535;' $NGINX_CONF
        fi
        
        if ! grep -q "use epoll" $NGINX_CONF; then
            sed -i '/events {/a\    use epoll;' $NGINX_CONF
        fi
    fi
    
    if ! grep -q "nginx soft nofile" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<EOF
nginx soft nofile 65535
nginx hard nofile 65535
nginx soft nproc 65535
nginx hard nproc 65535
EOF
    fi
    
    echo -e "${GREEN}系统优化完成${NC}"
}

set_ip(){
    if [ -f "$CONFIG" ]; then
        CURRENT_IP=$(grep -A 10 "upstream backend" $CONFIG | grep "^\s*server" | head -1 | awk '{print $2}' | cut -d: -f1)
        if [ -n "$CURRENT_IP" ]; then
            echo -e "${YELLOW}当前目标 IP: ${CURRENT_IP}${NC}"
        fi
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
    
    IFS='.' read -r -a ip_parts <<< "$TARGET_IP"
    for part in "${ip_parts[@]}"; do
        if [ "$part" -gt 255 ] || [ "$part" -lt 0 ]; then
            echo -e "${RED}IP 地址无效${NC}"
            return 1
        fi
    done
    
    # 修复后的 stream 配置 - 移除 upstream 块中不支持的 keepalive 指令
    cat > $CONFIG <<EOF
upstream backend {
    server ${TARGET_IP}:443 max_fails=3 fail_timeout=10s;
}

server {
    listen 443 reuseport;
    proxy_pass backend;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
    proxy_buffer_size 16k;
    proxy_socket_keepalive on;
}
EOF

    if nginx -t 2>&1; then
        systemctl restart nginx 2>/dev/null || service nginx restart 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}中转目标已修改为 ${TARGET_IP}:443，实时生效${NC}"
        else
            echo -e "${RED}Nginx 重启失败${NC}"
            return 1
        fi
    else
        echo -e "${RED}Nginx 配置测试失败${NC}"
        return 1
    fi
}

show_status(){
    echo
    echo -e "${BLUE}==============================${NC}"
    echo -e "${BLUE}       TCP 中转当前状态       ${NC}"
    echo -e "${BLUE}==============================${NC}"
    
    if systemctl is-active --quiet nginx 2>/dev/null || service nginx status >/dev/null 2>&1; then
        echo -e "Nginx: ${GREEN}运行中${NC}"
    else
        echo -e "Nginx: ${RED}未运行${NC}"
    fi
    
    if command -v nginx >/dev/null 2>&1; then
        NGINX_VERSION=$(nginx -v 2>&1 | cut -d/ -f2)
        if nginx -V 2>&1 | grep -q "with-stream"; then
            echo -e "版本: ${GREEN}${NGINX_VERSION}${NC} ${GREEN}(支持 stream)${NC}"
        else
            echo -e "版本: ${GREEN}${NGINX_VERSION}${NC} ${RED}(不支持 stream!)${NC}"
        fi
    fi
    
    if [ -f "$CONFIG" ]; then
        BACKEND_INFO=$(grep "^\s*server" $CONFIG | head -1 | awk '{print $2}' | tr -d ';')
        if [ -n "$BACKEND_INFO" ]; then
            echo -e "中转目标: ${GREEN}${BACKEND_INFO}${NC}"
            
            BACKEND_IP=$(echo $BACKEND_INFO | cut -d: -f1)
            BACKEND_PORT=$(echo $BACKEND_INFO | cut -d: -f2)
            
            if command -v timeout >/dev/null 2>&1; then
                if timeout 3 bash -c "echo >/dev/tcp/${BACKEND_IP}/${BACKEND_PORT}" 2>/dev/null; then
                    echo -e "后端连接: ${GREEN}可达${NC}"
                else
                    echo -e "后端连接: ${RED}不可达${NC}"
                fi
            elif command -v nc >/dev/null 2>&1; then
                if nc -z -w3 ${BACKEND_IP} ${BACKEND_PORT} 2>/dev/null; then
                    echo -e "后端连接: ${GREEN}可达${NC}"
                else
                    echo -e "后端连接: ${RED}不可达${NC}"
                fi
            fi
            
            if systemctl is-active --quiet nginx 2>/dev/null && command -v ss >/dev/null 2>&1; then
                CONNECTIONS=$(ss -tn state established '( sport = :443 or dport = :443 )' 2>/dev/null | tail -n +2 | wc -l)
                echo -e "端口443连接数: ${GREEN}${CONNECTIONS}${NC}"
            fi
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
                install_dep
                sys_opt
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
    install_dep
    sys_opt
    set_ip
fi

show_menu
