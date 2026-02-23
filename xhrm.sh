#!/bin/bash
set -e  # 遇到错误立即退出

# 颜色函数
function blue(){
    echo -e "\033[34m\033[01m$1\033[0m"
}
function green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
function red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
function yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

# 版本比较函数
function version_lt(){
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1"; 
}

# 错误处理函数
function error_exit(){
    red "错误: $1"
    exit 1
}

# 检查命令是否成功执行
function check_success(){
    if [ $? -ne 0 ]; then
        error_exit "$1"
    fi
}

# 加载系统信息
source /etc/os-release
RELEASE=$ID
VERSION=$VERSION_ID

# 检测系统类型
if [ "$RELEASE" == "centos" ]; then
    release="centos"
    systemPackage="yum"
    install_command="yum install -y"
    remove_command="yum remove -y"
elif [[ "$RELEASE" == "debian" || "$RELEASE" == "ubuntu" ]]; then
    release="$RELEASE"
    systemPackage="apt-get"
    install_command="apt-get install -y"
    remove_command="apt-get remove --purge -y"
else
    error_exit "不支持的系统类型: $RELEASE"
fi

systempwd="/etc/systemd/system/"

# 预检查函数
function preinstall_check(){
    yellow "开始预检查..."
    
    # 停止nginx如果正在运行
    if systemctl is-active --quiet nginx 2>/dev/null; then
        green "停止nginx服务..."
        systemctl stop nginx
    fi
    
    # 安装必要工具
    $install_command net-tools socat curl wget unzip zip tar >/dev/null 2>&1
    check_success "安装必要工具失败"
    
    # 检查端口占用
    Port80=`netstat -tlpn 2>/dev/null | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80 || true`
    Port443=`netstat -tlpn 2>/dev/null | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 443 || true`
    
    if [ -n "$Port80" ]; then
        process80=`netstat -tlpn 2>/dev/null | awk -F '[: ]+' '$5=="80"{print $9}'`
        error_exit "80端口被占用，占用进程为：${process80}"
    fi
    
    if [ -n "$Port443" ]; then
        process443=`netstat -tlpn 2>/dev/null | awk -F '[: ]+' '$5=="443"{print $9}'`
        error_exit "443端口被占用，占用进程为：${process443}"
    fi
    
    # 处理SELinux
    if [ -f "/etc/selinux/config" ]; then
        CHECK=$(grep SELINUX= /etc/selinux/config | grep -v "#")
        if [[ "$CHECK" == "SELINUX=enforcing" || "$CHECK" == "SELINUX=permissive" ]]; then
            green "关闭SELinux..."
            setenforce 0 2>/dev/null || true
            sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
        fi
    fi
    
    # 防火墙配置
    if [ "$release" == "centos" ]; then
        # CentOS版本检查
        if grep -q ' 6\.' /etc/redhat-release 2>/dev/null || grep -q ' 5\.' /etc/redhat-release 2>/dev/null; then
            error_exit "CentOS 5/6不受支持"
        fi
        
        # 配置firewalld
        if systemctl is-active --quiet firewalld; then
            green "配置firewalld规则..."
            firewall-cmd --zone=public --add-port=80/tcp --permanent
            firewall-cmd --zone=public --add-port=443/tcp --permanent
            firewall-cmd --reload
            check_success "firewalld配置失败"
        fi
        
        # 添加nginx仓库
        rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm --force --nodeps 2>/dev/null || true
        
    elif [ "$release" == "ubuntu" ]; then
        # Ubuntu版本检查
        if grep -q ' 14\.' /etc/os-release 2>/dev/null || grep -q ' 12\.' /etc/os-release 2>/dev/null; then
            error_exit "Ubuntu 12/14不受支持"
        fi
        
        # 配置ufw
        if systemctl is-active --quiet ufw; then
            green "配置ufw规则..."
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw reload
        fi
        
        apt-get update
        
    elif [ "$release" == "debian" ]; then
        # 配置ufw
        if systemctl is-active --quiet ufw; then
            green "配置ufw规则..."
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw reload
        fi
        
        apt-get update
    fi
    
    # 获取域名
    green "======================="
    blue "请输入绑定到云服务器的域名"
    green "======================="
    read your_domain
    
    # 验证域名解析
    real_addr=`ping -c 1 ${your_domain} 2>/dev/null | sed '1{s/[^(]*(//;s/).*//;q}'`
    if [ -z "$real_addr" ]; then
        error_exit "域名解析失败，请检查域名是否正确"
    fi
    
    local_addr=`curl -s --max-time 5 ipv4.icanhazip.com`
    if [ -z "$local_addr" ]; then
        local_addr=`curl -s --max-time 5 ifconfig.me`
    fi
    
    if [ "$real_addr" == "$local_addr" ]; then
        green "=========================================="
        green "       域名解析正常，开始安装trojan"
        green "=========================================="
        sleep 1s
        install_trojan "$your_domain"
    else
        red "===================================="
        red "域名解析地址: $real_addr"
        red "云服务器IP地址: $local_addr"
        red "两者不一致"
        red "===================================="
        read -p "是否强制继续？[y/N] :" yn
        if [[ $yn == [Yy] ]]; then
            yellow "强制继续安装..."
            install_trojan "$your_domain"
        else
            exit 1
        fi
    fi
}

# 安装trojan主函数
function install_trojan(){
    local your_domain="$1"
    
    if [ -z "$your_domain" ]; then
        error_exit "域名未设置"
    fi
    
    yellow "开始安装trojan，域名: $your_domain"
    
    # 安装nginx
    green "安装nginx..."
    $install_command nginx
    check_success "nginx安装失败"
    
    # 验证nginx安装
    if ! command -v nginx &> /dev/null; then
        error_exit "nginx安装失败，请检查系统"
    fi
    
    # 配置nginx
    green "配置nginx..."
    cat > /etc/nginx/nginx.conf <<-EOF
user  root;
worker_processes  1;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;
events {
    worker_connections  1024;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  120;
    client_max_body_size 20m;
    server {
        listen       80;
        server_name  $your_domain;
        root /usr/share/nginx/html;
        index index.php index.html index.htm;
    }
}
EOF
    
    systemctl restart nginx
    check_success "nginx启动失败"
    systemctl enable nginx
    
    # 下载伪装页面
    green "下载伪装页面..."
    rm -rf /usr/share/nginx/html/*
    cd /usr/share/nginx/html/
    
    if ! wget -q --timeout=10 https://raw.githubusercontent.com/xhrm/xhrm-back/master/index.zip; then
        yellow "下载伪装页面失败，使用默认页面"
        echo "<h1>Welcome to nginx!</h1>" > index.html
    else
        if ! unzip -q index.zip; then
            yellow "解压失败，使用默认页面"
            echo "<h1>Welcome to nginx!</h1>" > index.html
        fi
        rm -f index.zip
    fi
    
    sleep 3
    
    # 创建证书目录
    mkdir -p /usr/src/trojan-cert/$your_domain /usr/src/trojan-temp
    
    # 申请SSL证书
    green "申请SSL证书..."
    
    # 安装acme.sh
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -s https://get.acme.sh | sh
        check_success "acme.sh安装失败"
    fi
    
    # 生成随机邮箱
    random_email=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)@${your_domain}
    
    # 检查现有证书
    cert_success="0"
    
    if [ -f "/usr/src/trojan-cert/$your_domain/fullchain.cer" ]; then
        cd /usr/src/trojan-cert/$your_domain
        create_time=`stat -c %Y fullchain.cer 2>/dev/null || stat -f %m fullchain.cer 2>/dev/null`
        now_time=`date +%s`
        minus=$((now_time - create_time))
        
        if [ $minus -gt 5184000 ]; then
            yellow "证书已超过60天，重新申请..."
            ~/.acme.sh/acme.sh --register-account -m $random_email --server zerossl 2>/dev/null || true
            ~/.acme.sh/acme.sh --issue -d $your_domain --nginx --keylength 2048 --force
        else
            green "证书未超过60天，无需重新申请"
            cert_success="1"
        fi
    else
        ~/.acme.sh/acme.sh --register-account -m $random_email --server zerossl 2>/dev/null || true
        ~/.acme.sh/acme.sh --issue -d $your_domain --nginx --keylength 2048
    fi
    
    # 检查证书是否申请成功
    if [ -f "/root/.acme.sh/$your_domain/fullchain.cer" ]; then
        cert_success="1"
        
        # 安装证书
        ~/.acme.sh/acme.sh --installcert -d $your_domain \
            --key-file /usr/src/trojan-cert/$your_domain/private.key \
            --fullchain-file /usr/src/trojan-cert/$your_domain/fullchain.cer \
            --reloadcmd "systemctl restart trojan" 2>/dev/null || true
    fi
    
    if [ "$cert_success" == "1" ]; then
        green "证书申请成功"
        
        # 更新nginx配置
        cat > /etc/nginx/nginx.conf <<-EOF
user  root;
worker_processes  1;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;
events {
    worker_connections  1024;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  120;
    client_max_body_size 20m;
    server {
        listen       127.0.0.1:80;
        server_name  $your_domain;
        root /usr/share/nginx/html;
        index index.php index.html index.htm;
    }
    server {
        listen       0.0.0.0:80;
        server_name  $your_domain;
        return 301 https://$your_domain\$request_uri;
    }
}
EOF
        
        systemctl restart nginx
        check_success "nginx重启失败"
        
        # 下载trojan
        cd /usr/src
        green "获取最新版trojan..."
        
        # 获取最新版本
        LATEST_JSON=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest)
        latest_version=$(echo $LATEST_JSON | grep -oP '"tag_name": "\K(.*?)(?=")')
        latest_version=${latest_version#v}
        
        if [ -z "$latest_version" ]; then
            yellow "获取最新版本失败，使用默认版本1.16.0"
            latest_version="1.16.0"
        fi
        
        green "下载trojan v${latest_version}..."
        download_url="https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz"
        
        if ! wget -q --timeout=30 "$download_url"; then
            error_exit "trojan下载失败"
        fi
        
        tar xf trojan-${latest_version}-linux-amd64.tar.xz
        check_success "trojan解压失败"
        rm -f trojan-${latest_version}-linux-amd64.tar.xz
        
        # 生成随机密码
        green "生成trojan密码..."
        trojan_passwd=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | fold -w 16 | head -n 1)
        yellow "随机生成的密码: $trojan_passwd"
        yellow "请妥善保存此密码！"
        
        # 配置trojan
        cat > /usr/src/trojan/server.conf <<-EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "$trojan_passwd"
    ],
    "log_level": 1,
    "ssl": {
        "cert": "/usr/src/trojan-cert/$your_domain/fullchain.cer",
        "key": "/usr/src/trojan-cert/$your_domain/private.key",
        "key_password": "",
        "cipher": "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384",
        "cipher_tls13": "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
        "prefer_server_cipher": true,
        "alpn": [
            "http/1.1"
        ],
        "alpn_port_override": {
            "h2": 81
        },
        "reuse_session": true,
        "session_ticket": false,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "prefer_ipv4": false,
        "no_delay": true,
        "keep_alive": true,
        "reuse_port": false,
        "fast_open": false,
        "fast_open_qlen": 20
    },
    "mysql": {
        "enabled": false,
        "server_addr": "127.0.0.1",
        "server_port": 3306,
        "database": "trojan",
        "username": "trojan",
        "password": "",
        "key": "",
        "cert": "",
        "ca": ""
    }
}
EOF
        
        # 清理临时文件
        rm -rf /usr/src/trojan-temp/
        
        # 创建systemd服务
        cat > ${systempwd}trojan.service <<-EOF
[Unit]
Description=trojan
After=network.target

[Service]
Type=simple
PIDFile=/usr/src/trojan/trojan.pid
ExecStart=/usr/src/trojan/trojan -c "/usr/src/trojan/server.conf"
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=infinity
Restart=on-failure
RestartSec=1s

[Install]
WantedBy=multi-user.target
EOF
        
        chmod +x ${systempwd}trojan.service
        systemctl daemon-reload
        systemctl enable trojan.service
        systemctl start trojan.service
        
        check_success "trojan启动失败"
        
        # 输出安装信息
        clear
        green "=========================================================="
        green " Trojan安装完成！"
        green "=========================================================="
        green " 域名: $your_domain"
        green " 端口: 443"
        green " 密码: $trojan_passwd"
        green "=========================================================="
        green " 配置文件: /usr/src/trojan/server.conf"
        green " 证书目录: /usr/src/trojan-cert/$your_domain/"
        green "=========================================================="
        yellow " 请确保防火墙已开放443端口"
        green "=========================================================="
        
        # 保存密码到文件
        echo "域名: $your_domain" > /root/trojan_info.txt
        echo "密码: $trojan_passwd" >> /root/trojan_info.txt
        echo "端口: 443" >> /root/trojan_info.txt
        echo "配置文件: /usr/src/trojan/server.conf" >> /root/trojan_info.txt
        green "安装信息已保存到 /root/trojan_info.txt"
        
    else
        error_exit "证书申请失败，请检查域名解析和防火墙设置"
    fi
}

# 修复证书函数
function repair_cert(){
    yellow "开始修复证书..."
    
    # 停止nginx
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
    fi
    
    # 检查端口占用
    Port80=`netstat -tlpn 2>/dev/null | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80 || true`
    if [ -n "$Port80" ]; then
        process80=`netstat -tlpn 2>/dev/null | awk -F '[: ]+' '$5=="80"{print $9}'`
        error_exit "80端口被占用，占用进程为：${process80}"
    fi
    
    green "============================"
    blue "请输入绑定到云服务器的域名"
    blue "务必与之前使用的域名一致"
    green "============================"
    read your_domain
    
    if [ -z "$your_domain" ]; then
        error_exit "域名不能为空"
    fi
    
    # 验证域名解析
    real_addr=`ping -c 1 ${your_domain} 2>/dev/null | sed '1{s/[^(]*(//;s/).*//;q}'`
    if [ -z "$real_addr" ]; then
        error_exit "域名解析失败"
    fi
    
    local_addr=`curl -s --max-time 5 ipv4.icanhazip.com`
    
    if [ "$real_addr" != "$local_addr" ]; then
        red "域名解析地址与服务器IP不一致"
        read -p "是否强制继续？[y/N] :" yn
        if [[ ! $yn == [Yy] ]]; then
            exit 1
        fi
    fi
    
    # 安装acme.sh
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -s https://get.acme.sh | sh
        check_success "acme.sh安装失败"
    fi
    
    # 生成随机邮箱
    random_email=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)@${your_domain}
    
    # 创建证书目录
    mkdir -p /usr/src/trojan-cert/$your_domain
    
    # 申请证书
    ~/.acme.sh/acme.sh --register-account -m $random_email --server zerossl 2>/dev/null || true
    ~/.acme.sh/acme.sh --issue -d $your_domain --standalone --keylength 2048 --force
    
    if [ -f "/root/.acme.sh/$your_domain/fullchain.cer" ]; then
        ~/.acme.sh/acme.sh --installcert -d $your_domain \
            --key-file /usr/src/trojan-cert/$your_domain/private.key \
            --fullchain-file /usr/src/trojan-cert/$your_domain/fullchain.cer \
            --reloadcmd "systemctl restart trojan"
        
        green "证书申请成功"
        
        # 重启服务
        if systemctl is-active --quiet trojan; then
            systemctl restart trojan
        fi
        
        if systemctl is-active --quiet nginx; then
            systemctl start nginx
        fi
    else
        error_exit "证书申请失败"
    fi
}

# 卸载trojan函数
function remove_trojan(){
    yellow "开始卸载trojan..."
    
    read -p "是否确认卸载trojan和nginx？[y/N] :" yn
    if [[ ! $yn == [Yy] ]]; then
        green "取消卸载"
        return
    fi
    
    # 停止服务
    systemctl stop trojan 2>/dev/null || true
    systemctl disable trojan 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    
    # 删除服务文件
    rm -f ${systempwd}trojan.service
    systemctl daemon-reload
    
    # 卸载nginx
    if [ "$release" == "centos" ]; then
        $remove_command nginx nginx-common 2>/dev/null || true
        $remove_command nginx* 2>/dev/null || true
    else
        $remove_command nginx nginx-common nginx-full 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        apt-get autoclean -y 2>/dev/null || true
    fi
    
    # 删除相关目录
    rm -rf /usr/src/trojan/
    rm -rf /usr/src/trojan-cert/
    rm -rf /usr/share/nginx/html/*
    rm -rf /etc/nginx/
    rm -rf /root/.acme.sh/
    rm -f /root/trojan_info.txt
    
    green "=================================="
    green " trojan和nginx已卸载完成"
    green "=================================="
}

# 更新trojan函数
function update_trojan(){
    yellow "检查trojan更新..."
    
    if [ ! -f "/usr/src/trojan/trojan" ]; then
        error_exit "未找到trojan安装"
    fi
    
    # 获取当前版本
    curr_version=$(/usr/src/trojan/trojan -v 2>&1 | grep "trojan" | awk '{print $4}' | sed 's/v//')
    
    # 获取最新版本
    LATEST_JSON=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest)
    latest_version=$(echo $LATEST_JSON | grep -oP '"tag_name": "\K(.*?)(?=")')
    latest_version=${latest_version#v}
    
    if [ -z "$latest_version" ]; then
        error_exit "获取最新版本失败"
    fi
    
    green "当前版本: $curr_version"
    green "最新版本: $latest_version"
    
    if version_lt "$curr_version" "$latest_version"; then
        yellow "开始升级..."
        
        # 创建临时目录
        mkdir -p /tmp/trojan_update
        cd /tmp/trojan_update
        
        # 下载新版本
        download_url="https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz"
        wget -q "$download_url"
        check_success "下载失败"
        
        # 解压
        tar xf trojan-${latest_version}-linux-amd64.tar.xz
        check_success "解压失败"
        
        # 备份当前配置
        cp /usr/src/trojan/server.conf /tmp/server.conf.backup
        
        # 替换二进制文件
        cp -f ./trojan/trojan /usr/src/trojan/
        chmod +x /usr/src/trojan/trojan
        
        # 恢复配置
        cp /tmp/server.conf.backup /usr/src/trojan/server.conf
        
        # 清理
        cd /
        rm -rf /tmp/trojan_update
        
        # 重启服务
        systemctl restart trojan
        check_success "trojan重启失败"
        
        new_version=$(/usr/src/trojan/trojan -v 2>&1 | grep "trojan" | awk '{print $4}')
        green "升级完成，当前版本: $new_version"
    else
        green "已是最新版本，无需升级"
    fi
}

# 显示trojan信息函数
function show_info(){
    if [ -f "/root/trojan_info.txt" ]; then
        green "=================================="
        green " Trojan配置信息"
        green "=================================="
        cat /root/trojan_info.txt
        green "=================================="
    else
        yellow "未找到trojan配置信息文件"
    fi
}

# 主菜单
start_menu(){
    clear
    green " =============================================="
    green " Trojan一键安装脚本"
    green " 系统支持: CentOS 7+, Debian 9+, Ubuntu 16.04+"
    green " 作者: xhrm (优化版)"
    green " =============================================="
    yellow " 注意事项:"
    red "  1. 请确保80和443端口未被占用"
    red "  2. 域名需正确解析到本服务器"
    red "  3. 建议使用root用户运行"
    yellow " =============================================="
    echo
    green " 1. 安装trojan"
    red " 2. 卸载trojan"
    green " 3. 升级trojan"
    green " 4. 修复证书"
    green " 5. 查看配置信息"
    blue " 0. 退出脚本"
    echo
    read -p "请输入数字 [0-5]: " num
    
    case "$num" in
        1)
            preinstall_check
            ;;
        2)
            remove_trojan
            ;;
        3)
            update_trojan
            ;;
        4)
            repair_cert
            ;;
        5)
            show_info
            ;;
        0)
            exit 0
            ;;
        *)
            clear
            red "请输入正确数字 [0-5]"
            sleep 2s
            start_menu
            ;;
    esac
    
    # 返回菜单
    echo
    read -p "按回车键返回主菜单..." temp
    start_menu
}

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then 
    error_exit "请使用root用户运行此脚本"
fi

# 启动菜单
start_menu
