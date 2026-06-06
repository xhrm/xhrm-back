#!/bin/bash
# go一键安装脚本
# 支持 CentOS 7/8/9 和 Debian 系统

RED="\033[31m"      # Error message
GREEN="\033[32m"    # Success message
YELLOW="\033[33m"   # Warning message
BLUE="\033[36m"     # Info message
PLAIN='\033[0m'

# 获取系统信息
getSystemInfo() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        echo -e " ${RED}无法检测系统版本${PLAIN}"
        exit 1
    fi
    
    # 处理 CentOS 变体
    case $OS in
        centos|rhel|rocky|almalinux)
            OS="centos"
            ;;
        debian|ubuntu)
            OS="debian"
            ;;
        *)
            echo -e " ${RED}不支持的系统: $OS${PLAIN}"
            exit 1
            ;;
    esac
}

# 获取IPv4地址
IP=`curl -sL ipv4.icanhazip.com`
if [[ "$?" != "0" ]]; then
    echo "获取IPv4地址失败，尝试备用源..."
    IP=`curl -sL ifconfig.me`
    if [[ "$?" != "0" ]]; then
        IP=`curl -sL icanhazip.com`
        if [[ "$?" != "0" ]]; then
            echo -e " ${RED}获取IPv4地址失败，请检查网络${PLAIN}"
            exit 1
        fi
    fi
fi

NGINX_CONF_PATH="/etc/nginx/conf.d/"
ZIP_FILE="trojan-go"
CONFIG_FILE="/etc/trojan-go/config.json"
WS="false"

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

checkSystem() {
    getSystemInfo
    
    result=$(id | awk '{print $1}')
    if [[ $result != "uid=0(root)" ]]; then
        echo -e " ${RED}请以root身份执行该脚本${PLAIN}"
        exit 1
    fi

    # 设置包管理器相关变量
    if [[ "$OS" = "centos" ]]; then
        PMT="yum"
        CMD_INSTALL="yum install -y "
        CMD_REMOVE="yum remove -y "
        CMD_UPGRADE="yum update -y"
        
        # CentOS 8/9 需要启用 EPEL
        if [[ "$VER" =~ ^8 ]] || [[ "$VER" =~ ^9 ]]; then
            if ! rpm -q epel-release >/dev/null 2>&1; then
                echo "安装 EPEL 仓库..."
                $CMD_INSTALL epel-release
            fi
        fi
    elif [[ "$OS" = "debian" ]]; then
        PMT="apt"
        CMD_INSTALL="apt install -y "
        CMD_REMOVE="apt remove -y "
        CMD_UPGRADE="apt update; apt upgrade -y; apt autoremove -y"
        echo "更新软件包列表..."
        apt update >/dev/null 2>&1
    fi
    
    # 检查 systemd
    res=`which systemctl 2>/dev/null`
    if [[ "$?" != "0" ]]; then
        echo -e " ${RED}系统版本过低，请升级到最新版本${PLAIN}"
        exit 1
    fi
}

status() {
    trojan_cmd="$(command -v trojan-go)"
    if [[ "$trojan_cmd" = "" ]]; then
        echo 0
        return
    fi
    if [[ ! -f $CONFIG_FILE ]]; then
        echo 1
        return
    fi
    port=`grep local_port $CONFIG_FILE|cut -d: -f2| tr -d \",' '`
    res=`ss -ntlp 2>/dev/null | grep ${port} | grep trojan-go`
    if [[ -z "$res" ]]; then
        echo 2
    else
        echo 3
    fi
}

statusText() {
    res=`status`
    case $res in
        2)
            echo -e ${GREEN}已安装${PLAIN} ${RED}未运行${PLAIN}
            ;;
        3)
            echo -e ${GREEN}已安装${PLAIN} ${GREEN}正在运行${PLAIN}
            ;;
        *)
            echo -e ${RED}未安装${PLAIN}
            ;;
    esac
}

getVersion() {
    # 使用固定的稳定版本
    VERSION="1.0.5"
    colorEcho $BLUE "使用 trojan-go 版本: $VERSION"
}

archAffix() {
    case "${1:-"$(uname -m)"}" in
        i686|i386)
            echo '386'
        ;;
        x86_64|amd64)
            echo 'amd64'
        ;;
        armv7l|armv6l)
            echo 'armv7'
        ;;
        aarch64|armv8l)
            echo 'armv8'
        ;;
        *arm*)
            echo 'arm'
        ;;
        mips64le)
            echo 'mips64le'
        ;;
        mips64)
            echo 'mips64'
        ;;
        mipsle)
            echo 'mipsle-softfloat'
        ;;
        mips)
            echo 'mips-softfloat'
        ;;
        *)
            echo -e " ${RED}不支持的架构${PLAIN}"
            exit 1
        ;;
    esac
}

getData() {
    echo ""
    can_change=$1
    if [[ "$can_change" != "yes" ]]; then
        echo " go一键脚本，运行之前请确认如下条件已经具备："
        echo -e "  ${RED}1. 一个伪装域名${PLAIN}"
        echo -e "  ${RED}2. 伪装域名DNS解析指向当前服务器ip（${IP}）${PLAIN}"
        echo -e "  3. 如果/root目录下有 ${GREEN}*.pem${PLAIN} 和 ${GREEN}*.key${PLAIN} 证书密钥文件，无需理会条件2"
        echo " "
        read -p " 确认满足按y，按其他退出脚本：" answer
        if [[ "${answer,,}" != "y" ]]; then
            exit 0
        fi

        echo ""
        while true
        do
            read -p " 请输入伪装域名：" DOMAIN
            if [[ -z "${DOMAIN}" ]]; then
                echo -e " ${RED}伪装域名输入错误，请重新输入！${PLAIN}"
            else
                break
            fi
        done
        colorEcho $BLUE " 伪装域名(host)：$DOMAIN"

        echo ""
        DOMAIN=${DOMAIN,,}
        # 查找 /root 目录下的 .pem 和 .key 文件
        pem_file=$(find /root -maxdepth 1 -type f \( -name "*.pem" -o -name "*.crt" \) | head -1)
        key_file=$(find /root -maxdepth 1 -type f -name "*.key" | head -1)

        if [[ -f "$pem_file" && -f "$key_file" ]]; then
            echo -e "${GREEN} 检测到自有证书，将使用其部署${PLAIN}"
            CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
            KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
            USE_OWN_CERT=true
        else
            USE_OWN_CERT=false
            # 检查域名解析
            resolve=$(dig +short $DOMAIN @8.8.8.8 | head -1)
            if [[ -z "$resolve" ]]; then
                resolve=$(nslookup $DOMAIN 8.8.8.8 2>/dev/null | grep -A1 "Name:" | tail -1 | awk '{print $2}')
            fi
            if [[ -z "$resolve" ]]; then
                resolve=$(ping -c1 $DOMAIN | head -1 | grep -oP '(?<=\().*?(?=\))')
            fi
            if [[ "$resolve" != "$IP" ]]; then
                echo " ${DOMAIN} 解析结果：${resolve}"
                echo -e " ${RED}伪装域名未解析到当前服务器IP(${IP})!${PLAIN}"
                echo -e " ${YELLOW}请确保域名解析正确，或使用自有证书${PLAIN}"
                exit 1
            fi
        fi
    else
        DOMAIN=`grep sni $CONFIG_FILE | cut -d\" -f4`
        CERT_FILE=`grep cert $CONFIG_FILE | cut -d\" -f4`
        KEY_FILE=`grep key $CONFIG_FILE | cut -d\" -f4`
        read -p " 是否转换成WS版本？[y/n]" answer
        if [[ "${answer,,}" = "y" ]]; then
            WS="true"
        fi
    fi

    echo ""
    read -p " 请设置go密码（不输则随机生成）:" PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1`
    colorEcho $BLUE " go密码：$PASSWORD"
    echo ""

    read -p " 请输入go端口[100-65535的一个数字，默认443]：" PORT
    [[ -z "${PORT}" ]] && PORT=443
    if [[ "${PORT:0:1}" = "0" ]]; then
        echo -e "${RED}端口不能以0开头${PLAIN}"
        exit 1
    fi
    colorEcho $BLUE " go端口：$PORT"

    if [[ ${WS} = "true" ]]; then
        echo ""
        while true
        do
            read -p " 请输入伪装路径，以/开头(不懂请直接回车)：" WSPATH
            if [[ -z "${WSPATH}" ]]; then
                len=`shuf -i5-12 -n1`
                ws=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $len | head -n 1`
                WSPATH="/$ws"
                break
            elif [[ "${WSPATH:0:1}" != "/" ]]; then
                echo " 伪装路径必须以/开头！"
            elif [[ "${WSPATH}" = "/" ]]; then
                echo  " 不能使用根路径！"
            else
                break
            fi
        done
        echo ""
        colorEcho $BLUE " ws路径：$WSPATH"
    fi

    echo ""
    colorEcho $BLUE " 请选择伪装站类型:"
    echo "   1) 静态网站(位于/usr/share/nginx/html)"
    echo "   2) 自定义反代站点(需以http或者https开头)"
    read -p "  请选择伪装网站类型[默认：1]" answer

    if [[ -z "$answer" ]]; then
        answer="1"
    fi

    case $answer in
    1)
        PROXY_URL=""
        ;;
    2)
        read -p " 请输入反代站点(以http或者https开头)：" PROXY_URL
        if [[ -z "$PROXY_URL" ]]; then
            colorEcho $RED " 请输入反代网站！"
            exit 1
        elif [[ "${PROXY_URL:0:4}" != "http" ]]; then
            colorEcho $RED " 反代网站必须以http或https开头！"
            exit 1
        fi
        ;;
    *)
        colorEcho $RED " 请输入正确的选项！"
        exit 1
    esac

    REMOTE_HOST=`echo ${PROXY_URL} | cut -d/ -f3`
    echo ""
    colorEcho $BLUE " 伪装网站：$PROXY_URL"


    echo ""
    colorEcho $BLUE " 是否允许搜索引擎爬取网站？[默认：不允许]"
    echo "    y)允许，会有更多ip请求网站，但会消耗一些流量，vps流量充足情况下推荐使用"
    echo "    n)不允许，爬虫不会访问网站，访问ip比较单一，但能节省vps流量"
    read -p "  请选择：[y/n] " answer
    if [[ -z "$answer" ]]; then
        ALLOW_SPIDER="n"
    elif [[ "${answer,,}" = "n" ]]; then
        ALLOW_SPIDER="n"
    else
        ALLOW_SPIDER="y"
    fi
    echo ""

    colorEcho $BLUE " 允许搜索引擎：$ALLOW_SPIDER"
}

# ================= 定时重启功能 =================
DEFAULT_RESTART_TIME="00:10"
SERVICE_NAME="trojan-go"
LOG_FILE="/etc/trojan-go/log.txt"
CRON_MARKER="auto_restart_$SERVICE_NAME"
CRON_FILE="/etc/cron.d/trojan-go-autorestart"

getAutoRestartStatus() {
    if [[ -f "$CRON_FILE" ]] && grep -q "$CRON_MARKER" "$CRON_FILE"; then
        echo "enabled"
        local line=$(grep "$CRON_MARKER" "$CRON_FILE")
        local minute=$(echo "$line" | awk '{print $1}')
        local hour=$(echo "$line" | awk '{print $2}')
        printf -v CURRENT_RESTART_TIME "%02d:%02d" "$hour" "$minute"
    else
        echo "disabled"
        CURRENT_RESTART_TIME=""
    fi
}

setAutoRestart() {
    local time_str="${1:-$DEFAULT_RESTART_TIME}"
    local hour=$(echo "$time_str" | cut -d: -f1)
    local minute=$(echo "$time_str" | cut -d: -f2)
    
    hour=${hour#0}
    minute=${minute#0}
    [[ -z "$hour" ]] && hour=0
    [[ -z "$minute" ]] && minute=10

    # 确保 cron 服务启动
    if systemctl list-unit-files | grep -qE '^crond\.service'; then
        CRON_SERVICE="crond"
    elif systemctl list-unit-files | grep -qE '^cron\.service'; then
        CRON_SERVICE="cron"
    else
        echo "未找到 cron 服务，请确认已安装 cron。"
        return 1
    fi

    if ! systemctl is-active --quiet "$CRON_SERVICE"; then
        echo "正在启动 $CRON_SERVICE 服务..."
        systemctl start "$CRON_SERVICE"
        systemctl enable "$CRON_SERVICE" >/dev/null 2>&1 || true
    fi

    echo "$minute $hour * * * root rm -f $LOG_FILE; /bin/systemctl restart $SERVICE_NAME # $CRON_MARKER" > $CRON_FILE
    chmod 644 $CRON_FILE

    echo -e " ${BLUE}定时任务已设置：每天 $hour:$minute 清理日志并自动重启 $SERVICE_NAME${PLAIN}"
}

disableAutoRestart() {
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        echo -e " ${BLUE}服务定时重启已关闭${PLAIN}"
    else
        echo -e " ${YELLOW}服务定时重启未启用${PLAIN}"
    fi
}

modifyAutoRestartTime() {
    read -p "请输入新的服务重启时间 (格式 HH:MM，例如 00:10)：" NEW_TIME
    if [[ -z "$NEW_TIME" ]]; then
        echo "未输入新时间，取消修改"
        return
    fi
    if [[ ! $NEW_TIME =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "错误：时间格式无效，请使用 HH:MM"
        return 1
    fi
    
    disableAutoRestart
    setAutoRestart "$NEW_TIME"
}
# ================================================

installNginx() {
    echo ""
    colorEcho $BLUE " 安装nginx..."
    
    if [[ "$OS" = "centos" ]]; then
        # CentOS 使用 nginx 官方源
        if [[ ! -f /etc/yum.repos.d/nginx.repo ]]; then
            cat > /etc/yum.repos.d/nginx.repo <<-EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
        fi
    fi
    
    $CMD_INSTALL nginx
    if [[ "$?" != "0" ]]; then
        colorEcho $RED " Nginx安装失败，尝试使用系统默认源..."
        if [[ "$OS" = "centos" ]]; then
            $CMD_INSTALL nginx
        fi
    fi
    systemctl enable nginx
}

startNginx() {
    systemctl start nginx 2>/dev/null || true
}

stopNginx() {
    systemctl stop nginx 2>/dev/null || true
}

reloadNginx() {
    systemctl reload nginx 2>/dev/null || startNginx
}

getCert() {
    mkdir -p /etc/trojan-go
    
    if [[ "$USE_OWN_CERT" = "true" ]]; then
        echo -e "${GREEN} 使用自有证书${PLAIN}"
        cp "$pem_file" "$CERT_FILE"
        cp "$key_file" "$KEY_FILE"
        return
    fi
    
    # 检查是否已有证书
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        echo -e "${GREEN} 检测到已有证书，跳过申请${PLAIN}"
        return
    fi
    
    stopNginx
    systemctl stop trojan-go 2>/dev/null || true
    sleep 2
    
    # 检查端口占用
    res=$(ss -tlnp 2>/dev/null | grep -E ':80 |:443 ')
    if [[ "${res}" != "" ]]; then
        echo -e "${YELLOW} 检测到端口占用，尝试停止相关服务...${PLAIN}"
        systemctl stop httpd 2>/dev/null || true
        systemctl stop apache2 2>/dev/null || true
        sleep 2
    fi

    $CMD_INSTALL socat openssl curl
    
    # 安装 acme.sh
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        echo "安装 acme.sh..."
        curl -sL https://get.acme.sh | sh -s email=admin@${DOMAIN}
        source ~/.bashrc
    fi
    
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    echo "申请 SSL 证书..."
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --keylength ec-256 --standalone
    
    if [[ ! -f ~/.acme.sh/${DOMAIN}_ecc/ca.cer ]]; then
        colorEcho $RED " 获取证书失败"
        exit 1
    fi
    
    CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
    KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
        --key-file $KEY_FILE \
        --fullchain-file $CERT_FILE \
        --reloadcmd "systemctl reload nginx"
        
    if [[ ! -f $CERT_FILE || ! -f $KEY_FILE ]]; then
        colorEcho $RED " 安装证书失败"
        exit 1
    fi
    
    echo -e "${GREEN} SSL 证书申请成功${PLAIN}"
}

configNginx() {
    mkdir -p /usr/share/nginx/html
    
    # 创建默认首页
    cat > /usr/share/nginx/html/index.html <<-EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
</head>
<body>
    <h1>Welcome to nginx!</h1>
</body>
</html>
EOF

    if [[ "$ALLOW_SPIDER" = "n" ]]; then
        echo 'User-Agent: *' > /usr/share/nginx/html/robots.txt
        echo 'Disallow: /' >> /usr/share/nginx/html/robots.txt
        ROBOT_CONFIG="    location = /robots.txt {}"
    else
        ROBOT_CONFIG=""
    fi
    
    # 备份原始配置
    if [[ -f /etc/nginx/nginx.conf ]] && [[ ! -f /etc/nginx/nginx.conf.bak ]]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    fi
    
    # 获取 nginx 用户
    if [[ "$OS" = "centos" ]]; then
        user="nginx"
    else
        user="www-data"
    fi
    
    # 生成 nginx 配置
    cat > /etc/nginx/nginx.conf <<-EOF
user $user;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    server_tokens off;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    gzip                on;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    include /etc/nginx/conf.d/*.conf;
}
EOF

    mkdir -p $NGINX_CONF_PATH
    if [[ "$PROXY_URL" = "" ]]; then
        cat > $NGINX_CONF_PATH${DOMAIN}.conf <<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;
    index index.html;

    $ROBOT_CONFIG
}
EOF
    else
        cat > $NGINX_CONF_PATH${DOMAIN}.conf <<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;
    
    location / {
        proxy_ssl_server_name on;
        proxy_pass $PROXY_URL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Accept-Encoding '';
        sub_filter "$REMOTE_HOST" "$DOMAIN";
        sub_filter_once off;
    }
    
    $ROBOT_CONFIG
}
EOF
    fi
}

downloadFile() {
    SUFFIX=`archAffix`
    
    # 使用 GitHub 代理或直接下载
    DOWNLOAD_URL="https://github.com/p4gefau1t/trojan-go/releases/download/v${VERSION}/trojan-go-linux-${SUFFIX}.zip"
    
    echo "下载 trojan-go v${VERSION}..."
    wget -q --show-progress -O /tmp/${ZIP_FILE}.zip $DOWNLOAD_URL || {
        # 备用下载地址
        DOWNLOAD_URL="https://ghproxy.com/https://github.com/p4gefau1t/trojan-go/releases/download/v${VERSION}/trojan-go-linux-${SUFFIX}.zip"
        wget -q --show-progress -O /tmp/${ZIP_FILE}.zip $DOWNLOAD_URL
    }
    
    if [[ ! -f /tmp/${ZIP_FILE}.zip ]] || [[ ! -s /tmp/${ZIP_FILE}.zip ]]; then
        echo -e "${RED} go安装文件下载失败，请检查网络或重试${PLAIN}"
        exit 1
    fi
    
    # 验证 zip 文件
    if ! unzip -t /tmp/${ZIP_FILE}.zip >/dev/null 2>&1; then
        echo -e "${RED} 下载的文件损坏，请重试${PLAIN}"
        rm -f /tmp/${ZIP_FILE}.zip
        exit 1
    fi
    
    echo "下载静态网站模板..."
    wget -q --show-progress -O /tmp/html.zip https://raw.githubusercontent.com/xhrm/xhrm-back/master/index.zip || {
        # 如果下载失败，创建默认页面
        echo "创建默认静态页面..."
        mkdir -p /usr/share/nginx/html
        cat > /usr/share/nginx/html/index.html <<-EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body><h1>Welcome</h1></body>
</html>
EOF
        return
    }
}

installTrojan() {
    rm -rf /tmp/${ZIP_FILE}
    
    # 解压 trojan-go
    unzip -q /tmp/${ZIP_FILE}.zip -d /tmp/${ZIP_FILE}
    if [[ ! -f /tmp/${ZIP_FILE}/trojan-go ]]; then
        echo -e "${RED} 解压失败，文件结构不正确${PLAIN}"
        ls -la /tmp/${ZIP_FILE}/
        exit 1
    fi
    
    # 解压静态网站模板（如果存在）
    if [[ -f /tmp/html.zip ]]; then
        rm -rf /usr/share/nginx/html/*
        unzip -q /tmp/html.zip -d /usr/share/nginx/html/ 2>/dev/null || true
    fi
    
    # 安装 trojan-go
    cp /tmp/${ZIP_FILE}/trojan-go /usr/bin/
    chmod +x /usr/bin/trojan-go
    
    # 创建配置目录
    mkdir -p /etc/trojan-go
    
    # 复制数据文件（如果存在）
    if [[ -f /tmp/${ZIP_FILE}/geoip.dat ]]; then
        cp /tmp/${ZIP_FILE}/geoip.dat /etc/trojan-go/
    fi
    if [[ -f /tmp/${ZIP_FILE}/geosite.dat ]]; then
        cp /tmp/${ZIP_FILE}/geosite.dat /etc/trojan-go/
    fi
    
    # 创建 systemd 服务文件
    cat > /etc/systemd/system/trojan-go.service <<-EOF
[Unit]
Description=trojan-go
After=network.target nss-lookup.target

[Service]
Type=simple
StandardError=journal
ExecStart=/usr/bin/trojan-go -config /etc/trojan-go/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable trojan-go
    
    rm -rf /tmp/${ZIP_FILE}
    colorEcho $BLUE " go安装成功！"
}

configTrojan() {
    mkdir -p /etc/trojan-go
    
    # 处理 websocket 配置
    WS_BOOL="false"
    [[ "$WS" = "true" ]] && WS_BOOL="true"
    
    cat > $CONFIG_FILE <<-EOF
{
    "run_type": "server",
    "local_addr": "::",
    "local_port": ${PORT},
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "$PASSWORD"
    ],
    "log_level": 0,
    "log_file": "/etc/trojan-go/log.txt",
    "disable_http_check": false,
    "udp_timeout": 60,
    "ssl": {
        "verify": true,
        "verify_hostname": true,
        "cert": "${CERT_FILE}",
        "key": "${KEY_FILE}",
        "sni": "${DOMAIN}",
        "alpn": [
            "http/1.1"
        ],
        "session_ticket": true,
        "reuse_session": true,
        "fingerprint": "chrome"
    },
    "websocket": {
        "enabled": ${WS_BOOL},
        "path": "${WSPATH}",
        "host": "${DOMAIN}"
    }
}
EOF
}

setSelinux() {
    if [[ -s /etc/selinux/config ]] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
        setenforce 0
        echo -e "${GREEN} SELinux 已设置为宽松模式${PLAIN}"
    fi
}

setFirewall() {
    # 检查防火墙状态并开放端口
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        if [[ "$PORT" != "443" ]]; then
            firewall-cmd --permanent --add-port=${PORT}/tcp
        fi
        firewall-cmd --reload
        echo -e "${GREEN} 防火墙规则已添加${PLAIN}"
    elif command -v ufw &>/dev/null && ufw status | grep -q active; then
        ufw allow http
        ufw allow https
        if [[ "$PORT" != "443" ]]; then
            ufw allow ${PORT}/tcp
        fi
        echo -e "${GREEN} UFW 规则已添加${PLAIN}"
    elif command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT &>/dev/null; then
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            iptables -I INPUT -p tcp --dport 443 -j ACCEPT
            if [[ "$PORT" != "443" ]]; then
                iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
            fi
            # 保存规则
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables.rules 2>/dev/null || true
            fi
        fi
    fi
}

install() {
    checkSystem
    
    echo ""
    colorEcho $BLUE "检测到系统: $OS $VER"
    
    getData

    if [[ "$OS" = "centos" ]]; then
        yum clean all
    else
        apt update
    fi
    
    $CMD_INSTALL wget vim unzip tar gcc openssl curl net-tools dnsutils bind-utils 2>/dev/null || \
    $CMD_INSTALL wget vim unzip tar gcc openssl curl net-tools
    
    if [[ "$OS" = "debian" ]]; then
        $CMD_INSTALL libssl-dev g++
    fi
    
    res=$(which unzip 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e " ${RED}unzip安装失败，请检查网络${PLAIN}"
        exit 1
    fi

    installNginx
    setFirewall
    configNginx
    startNginx
    
    getCert

    echo " 安装go..."
    getVersion
    downloadFile
    installTrojan
    configTrojan

    setSelinux

    start
    setAutoRestart
    showInfo
}

start() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e "${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    startNginx
    systemctl restart trojan-go
    sleep 2
    port=`grep local_port $CONFIG_FILE|cut -d: -f2| tr -d \",' '`
    res=`ss -ntlp 2>/dev/null | grep ${port} | grep trojan-go`
    if [[ "$res" = "" ]]; then
        colorEcho $RED " go启动失败，请检查日志: journalctl -u trojan-go -n 50"
    else
        colorEcho $BLUE " go启动成功"
    fi
}

stop() {
    stopNginx
    systemctl stop trojan-go
    colorEcho $BLUE " go停止成功"
}

restart() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    stop
    start
}

reconfig() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    line1=`grep -n 'websocket' $CONFIG_FILE  | head -n1 | cut -d: -f1`
    line11=`expr $line1 + 1`
    WS=`sed -n "${line11}p" $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
    getData true
    configTrojan
    setFirewall
    getCert
    configNginx
    stop
    start
    showInfo
}

showInfo() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    domain=`grep '"sni"' $CONFIG_FILE | cut -d\" -f4`
    port=`grep local_port $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
    password=`grep -A1 '"password"' $CONFIG_FILE | tail -1 | tr -d \"' ', | xargs`
    ws=`grep '"websocket"' $CONFIG_FILE -A1 | tail -1 | grep -o 'true\|false'`
    
    echo ""
    echo -n " go运行状态："
    statusText
    echo ""
    echo -e " ${BLUE}系统信息: ${PLAIN}${OS} ${VER}"
    echo -e " ${BLUE}go配置文件: ${PLAIN} ${RED}${CONFIG_FILE}${PLAIN}"
    echo -e " ${BLUE}go配置信息：${PLAIN}"
    echo -e "   IP：${RED}$IP${PLAIN}"
    echo -e "   伪装域名/主机名(host)/SNI/peer名称：${RED}$domain${PLAIN}"
    echo -e "   端口(port)：${RED}$port${PLAIN}"
    echo -e "   密码(password)：${RED}$password${PLAIN}"
    if [[ "$ws" = "true" ]]; then
        echo -e "   websocket：${RED}true${PLAIN}"
        wspath=`grep '"path"' $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
        echo -e "   ws路径(ws path)：${RED}${wspath}${PLAIN}"
    fi
    echo ""
}

showLog() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e "${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    journalctl -u trojan-go -n 50 --no-pager
}

showCronStatus() {
    local status=$(getAutoRestartStatus)
    echo ""
    echo -e "${BLUE}========== 定时任务状态 ==========${PLAIN}"
    if [[ "$status" = "enabled" ]]; then
        echo -e "  trojan-go服务定时重启: ${GREEN}已启用${PLAIN}"
        echo -e "  执行时间: 每天 ${CURRENT_RESTART_TIME}"
        echo -e "  执行动作: 清理日志文件并重启 trojan-go 服务"
    else
        echo -e "  trojan-go服务定时重启: ${RED}已禁用${PLAIN}"
    fi
    echo -e "${BLUE}==================================${PLAIN}"
    echo ""
}

menu() {
    clear
    echo -e "  ${RED}GO install${PLAIN}"
    echo -e "  支持系统: CentOS 7/8/9, Debian, Ubuntu"
    echo ""

    echo -e "  ${GREEN}1.${PLAIN}  安装go"
    echo -e "  ${GREEN}2.${PLAIN}  安装go+WS"
    echo " -------------"
    echo -e "  ${GREEN}3.${PLAIN}  启动go"
    echo -e "  ${GREEN}4.${PLAIN}  重启go"
    echo -e "  ${GREEN}5.${PLAIN}  停止go"
    echo " -------------"
    echo -e "  ${GREEN}6.${PLAIN}  查看go配置"
    echo -e "  ${GREEN}7.${RED}  修改go配置${PLAIN}"
    echo -e "  ${GREEN}8.${PLAIN}  查看go日志"
    echo " -------------"
    echo -e "  ${GREEN}9.${PLAIN}  定时重启管理"
    echo " -------------"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo 
    echo -n " 当前状态："
    statusText
    echo 

    read -p " 请选择操作[0-9]：" answer
    case $answer in
        0)
            exit 0
            ;;
        1)
            install
            ;;
        2)
            WS="true"
            install
            ;;
        3)
            start
            ;;
        4)
            restart
            ;;
        5)
            stop
            ;;
        6)
            showInfo
            ;;
        7)
            reconfig
            ;;
        8)
            showLog
            ;;
        9)
            echo ""
            echo -e "${BLUE}========== 定时重启管理 ==========${PLAIN}"
            echo " 1) 开启定时重启"
            echo " 2) 关闭定时重启"
            echo " 3) 修改重启时间"
            echo " 4) 查看定时任务状态"
            echo " 0) 返回主菜单"
            echo -e "${BLUE}==================================${PLAIN}"
            read -p " 请选择[0-4]：" sub_answer
            case $sub_answer in
                1)
                    if [[ "$(getAutoRestartStatus)" = "enabled" ]]; then
                        echo -e " ${YELLOW}定时重启已开启，当前时间: $CURRENT_RESTART_TIME${PLAIN}"
                        read -p " 是否要修改时间？[y/n] " modify_ans
                        if [[ "${modify_ans,,}" = "y" ]]; then
                            modifyAutoRestartTime
                        fi
                    else
                        read -p " 请输入重启时间 (格式 HH:MM，默认 00:10)：" new_time
                        if [[ -z "$new_time" ]]; then
                            setAutoRestart
                        else
                            if [[ ! $new_time =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                                echo "错误：时间格式无效，使用默认时间 00:10"
                                setAutoRestart
                            else
                                setAutoRestart "$new_time"
                            fi
                        fi
                    fi
                    ;;
                2)
                    disableAutoRestart
                    ;;
                3)
                    modifyAutoRestartTime
                    ;;
                4)
                    showCronStatus
                    read -p " 按回车键返回..."
                    ;;
                *)
                    ;;
            esac
            ;;
        *)
            echo -e "$RED 请选择正确的操作！${PLAIN}"
            exit 1
            ;;
    esac
}

# 命令行参数处理
case "$1" in
    menu|start|restart|stop|showInfo|showLog)
        checkSystem
        ${1}
        ;;
    "")
        checkSystem
        menu
        ;;
    *)
        echo " 参数错误"
        echo " 用法: `basename $0` [menu|start|restart|stop|showInfo|showLog]"
        exit 1
        ;;
esac
