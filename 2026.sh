#!/bin/bash
# go一键安装脚本


RED="\033[31m"      # Error message
GREEN="\033[32m"    # Success message
YELLOW="\033[33m"   # Warning message
BLUE="\033[36m"     # Info message
PLAIN='\033[0m'

OS=`hostnamectl | grep -i system | cut -d: -f2`

# 获取IPv4地址
IP=`curl -sL ipv4.icanhazip.com`
if [[ "$?" != "0" ]]; then
    echo "获取IPv4地址失败。"
    exit 1
fi

BT="false"
NGINX_CONF_PATH="/etc/nginx/conf.d/"

# 检查是否安装宝塔面板
res=`which bt 2>/dev/null`
if [[ "$res" != "" ]]; then
    BT="true"
    NGINX_CONF_PATH="/www/server/panel/vhost/nginx/"
fi


ZIP_FILE="trojan-go"
CONFIG_FILE="/etc/trojan-go/config.json"

WS="false"

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

checkSystem() {
    result=$(id | awk '{print $1}')
    if [[ $result != "uid=0(root)" ]]; then
        echo -e " ${RED}请以root身份执行该脚本${PLAIN}"
        exit 1
    fi

    res=`which yum 2>/dev/null`
    if [[ "$?" != "0" ]]; then
        res=`which apt 2>/dev/null`
        if [[ "$?" != "0" ]]; then
            echo -e " ${RED}不受支持的Linux系统${PLAIN}"
            exit 1
        fi
        PMT="apt"
        CMD_INSTALL="apt install -y "
        CMD_REMOVE="apt remove -y "
        CMD_UPGRADE="apt update; apt upgrade -y; apt autoremove -y"
    else
        PMT="yum"
        CMD_INSTALL="yum install -y "
        CMD_REMOVE="yum remove -y "
        CMD_UPGRADE="yum update -y"
    fi
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
    res=`ss -ntlp| grep ${port} | grep trojan-go`
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
    VERSION=`curl -fsSL ${V6_PROXY}https://api.github.com/repos/fregie/trojan-go/releases | grep tag_name | sed -E 's/.*"v(.*)".*/\1/'| head -n1`
    if [[ ${VERSION:0:1} != "v" ]];then
        VERSION="v${VERSION}"
    fi
}

archAffix() {
    case "${1:-"$(uname -m)"}" in
        i686|i386)
            echo '386'
        ;;
        x86_64|amd64)
            echo 'amd64'
        ;;
        *armv7*|armv6l)
            echo 'armv7'
        ;;
        *armv8*|aarch64)
            echo 'armv8'
        ;;
        *armv6*)
            echo 'armv6'
        ;;
        *arm*)
            echo 'arm'
        ;;
        *mips64le*)
            echo 'mips64le'
        ;;
        *mips64*)
            echo 'mips64'
        ;;
        *mipsle*)
            echo 'mipsle-softfloat'
        ;;
        *mips*)
            echo 'mips-softfloat'
        ;;
        *)
            return 1
        ;;
    esac

	return 0
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
        pem_file=$(find /root -maxdepth 1 -type f -name "*.pem")
        key_file=$(find /root -maxdepth 1 -type f -name "*.key")

        if [[ -f "$pem_file" && -f "$key_file" ]]; then
            echo -e "${GREEN} 检测到自有证书，将使用其部署${PLAIN}"
            CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
            KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
        else
            resolve=`curl -sL ipv4.icanhazip.com`
            res=`echo -n ${resolve} | grep ${IP}`
            if [[ -z "${res}" ]]; then
                echo " ${DOMAIN} 解析结果：${resolve}"
                echo -e " ${RED}伪装域名未解析到当前服务器IP(${IP})!${PLAIN}"
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

    # 如果用户没有输入，则使用默认选项 1
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
        ALLOW_SPIDER="n"  # 默认改为 "n"
    elif [[ "${answer,,}" = "n" ]]; then
        ALLOW_SPIDER="n"
    else
        ALLOW_SPIDER="y"
    fi
    echo ""

    colorEcho $BLUE " 允许搜索引擎：$ALLOW_SPIDER"
}

installNginx() {
    echo ""
    colorEcho $BLUE " 安装nginx..."
    if [[ "$BT" = "false" ]]; then
        if [[ "$PMT" = "yum" ]]; then
            $CMD_INSTALL epel-release
            if [[ "$?" != "0" ]]; then
                echo '[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true' > /etc/yum.repos.d/nginx.repo
            fi
        fi
        $CMD_INSTALL nginx
        if [[ "$?" != "0" ]]; then
            colorEcho $RED " Nginx安装失败"
            exit 1
        fi
        systemctl enable nginx
    else
        res=`which nginx 2>/dev/null`
        if [[ "$?" != "0" ]]; then
            colorEcho $RED " 您安装了宝塔，请在宝塔后台安装nginx后再运行本脚本"
            exit 1
        fi
    fi
}

startNginx() {
    if [[ "$BT" = "false" ]]; then
        systemctl start nginx
    else
        nginx -c /www/server/nginx/conf/nginx.conf
    fi
}

stopNginx() {
    if [[ "$BT" = "false" ]]; then
        systemctl stop nginx
    else
        res=`ps aux | grep -i nginx`
        if [[ "$res" != "" ]]; then
            nginx -s stop
        fi
    fi
}

getCert() {
    mkdir -p /etc/trojan-go
    if [[ -z ${CERT_FILE+x} ]]; then
        stopNginx
        systemctl stop trojan-go
        sleep 2
        res=$(ss -ntlp | grep -E ':80 |:443 ')
        if [[ "${res}" != "" ]]; then
            echo -e "${RED} 其他进程占用了80或443端口，请先关闭再运行一键脚本${PLAIN}"
            echo " 端口占用信息如下："
            echo ${res}
            exit 1
        fi

        $CMD_INSTALL socat openssl
        if [[ "$PMT" = "yum" ]]; then
            $CMD_INSTALL cronie
            systemctl start crond
            systemctl enable crond
        else
            $CMD_INSTALL cron
            systemctl start cron
            systemctl enable cron
        fi
        curl -sL https://get.acme.sh | sh -s email=bangs@spxcode.com
        source ~/.bashrc
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if [[ "$BT" = "false" ]]; then
            ~/.acme.sh/acme.sh --issue -d $DOMAIN --keylength ec-256 --pre-hook "systemctl stop nginx" --post-hook "systemctl restart nginx" --standalone
        else
            ~/.acme.sh/acme.sh --issue -d $DOMAIN --keylength ec-256 --pre-hook "nginx -s stop || { echo -n ''; }" --post-hook "nginx -c /www/server/nginx/conf/nginx.conf || { echo -n ''; }" --standalone
        fi
        [[ -f ~/.acme.sh/${DOMAIN}_ecc/ca.cer ]] || {
            colorEcho $RED " 获取证书失败"
            exit 1
        }
        CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
        KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
            --key-file $KEY_FILE \
            --fullchain-file $CERT_FILE \
            --reloadcmd "service nginx force-reload"
        [[ -f $CERT_FILE && -f $KEY_FILE ]] || {
            colorEcho $RED " 获取证书失败"
            exit 1
        }
    else
        # 动态匹配 .pem 和 .key 文件
        pem_file=$(find /root -maxdepth 1 -type f -name "*.pem")
        key_file=$(find /root -maxdepth 1 -type f -name "*.key")

        if [[ -f "$pem_file" && -f "$key_file" ]]; then
            echo -e "${GREEN} 检测到自有证书，将使用其部署${PLAIN}"
            CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
            KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
            
            # 将找到的文件复制到指定位置
            cp "$pem_file" "$CERT_FILE"
            cp "$key_file" "$KEY_FILE"
        else
            echo -e "${RED} 未找到自有证书文件 (.pem/.key)${PLAIN}"
            exit 1
        fi
    fi
}


configNginx() {
    mkdir -p /usr/share/nginx/html
    if [[ "$ALLOW_SPIDER" = "n" ]]; then
        echo 'User-Agent: *' > /usr/share/nginx/html/robots.txt
        echo 'Disallow: /' >> /usr/share/nginx/html/robots.txt
        ROBOT_CONFIG="    location = /robots.txt {}"
    else
        ROBOT_CONFIG=""
    fi
    if [[ "$BT" = "false" ]]; then
        if [[ ! -f /etc/nginx/nginx.conf.bak ]]; then
            mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
        fi
        res=`id nginx 2>/dev/null`
        if [[ "$?" != "0" ]]; then
            user="www-data"
        else
            user="nginx"
        fi
        cat > /etc/nginx/nginx.conf<<-EOF
user $user;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

# Load dynamic modules. See /usr/share/doc/nginx/README.dynamic.
include /usr/share/nginx/modules/*.conf;

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

    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    mkdir -p $NGINX_CONF_PATH
    if [[ "$PROXY_URL" = "" ]]; then
        cat > $NGINX_CONF_PATH${DOMAIN}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;

    $ROBOT_CONFIG
}
EOF
    else
        cat > $NGINX_CONF_PATH${DOMAIN}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;
    location / {
        proxy_ssl_server_name on;
        proxy_pass $PROXY_URL;
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
    DOWNLOAD_URL="${V6_PROXY}https://github.com/fregie/trojan-go/releases/download/${VERSION}/trojan-go-linux-${SUFFIX}.zip"
    wget -O /tmp/${ZIP_FILE}.zip $DOWNLOAD_URL
    wget -O /tmp/html.zip https://raw.githubusercontent.com/xhrm/xhrm-back/master/index.zip
    if [[ ! -f /tmp/${ZIP_FILE}.zip ]]; then
        echo -e "{$RED} go安装文件下载失败，请检查网络或重试${PLAIN}"
        exit 1
    fi
}

installTrojan() {
    rm -rf /tmp/${ZIP_FILE}
    unzip /tmp/${ZIP_FILE}.zip  -d /tmp/${ZIP_FILE}
    rm -rf /usr/share/nginx/html/*
    unzip /tmp/html.zip  -d /usr/share/nginx/html/
    cp /tmp/${ZIP_FILE}/trojan-go /usr/bin
    cp /tmp/${ZIP_FILE}/geoip.dat /etc/trojan-go
    cp /tmp/${ZIP_FILE}/geosite.dat /etc/trojan-go
    cp /tmp/${ZIP_FILE}/example/trojan-go.service /etc/systemd/system/
    sed -i '/User=nobody/d' /etc/systemd/system/trojan-go.service
    systemctl daemon-reload
    
    systemctl enable trojan-go
    rm -rf /tmp/${ZIP_FILE}

    colorEcho $BLUE " go安装成功！"
}

configTrojan() {
    mkdir -p /etc/trojan-go
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
	"log_level": 2,
	"log_file": "/etc/trojan-go/log.txt",
	"disable_http_check": false,
	"udp_timeout": 60,
  "ssl": {
    "verify": true,
    "verify_hostname": true,
    "cert": "${CERT_FILE}",
    "key": "${KEY_FILE}",
    "key_password": "",
    "cipher": "",
    "curves": "",
    "prefer_server_cipher": false,
    "sni": "",
    "alpn": [
      "http/1.1"
    ],
    "session_ticket": true,
    "reuse_session": true,
    "plain_http_response": "",
    "fallback_addr": "",
    "fallback_port": 0,
    "fingerprint": "firefox"
  },
  "tcp": {
    "no_delay": true,
    "keep_alive": true,
    "prefer_ipv4": true
  },
  "mux": {
    "enabled": true,
    "concurrency": 8,
    "idle_timeout": 0
  },
  "router": {
    "enabled": false,
    "bypass": [],
    "proxy": [],
    "block": [],
    "default_policy": "proxy",
    "domain_strategy": "as_is",
    "geoip": "/etc/trojan-go/geoip.dat",
    "geosite": "/etc/trojan-go/geosite.dat"
  },
  "websocket": {
    "enabled": ${WS},
    "path": "${WSPATH}",
    "host": "${DOMAIN}"
  },
  "shadowsocks": {
    "enabled": false,
    "method": "AES-128-GCM",
    "password": ""
  },
  "transport_plugin": {
    "enabled": false,
    "type": "",
    "command": "",
    "option": "",
    "arg": [],
    "env": []
  },
  "forward_proxy": {
    "enabled": false,
    "proxy_addr": "",
    "proxy_port": 0,
    "username": "",
    "password": ""
  },
  "mysql": {
    "enabled": false,
    "server_addr": "localhost",
    "server_port": 3306,
    "database": "",
    "username": "",
    "password": "",
    "check_rate": 60
  },
  "api": {
    "enabled": false,
    "api_addr": "",
    "api_port": 0,
    "ssl": {
    "enabled": false,
    "key": "",
    "cert": "",
    "verify_client": false,
    "client_cert": []
    }
  }
}
EOF
}

setSelinux() {
    if [[ -s /etc/selinux/config ]] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
        setenforce 0
    fi
}

setFirewall() {
    res=`which firewall-cmd 2>/dev/null`
    if [[ $? -eq 0 ]]; then
        systemctl status firewalld > /dev/null 2>&1
        if [[ $? -eq 0 ]];then
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            if [[ "$PORT" != "443" ]]; then
                firewall-cmd --permanent --add-port=${PORT}/tcp
            fi
            firewall-cmd --reload
        else
            nl=`iptables -nL | nl | grep FORWARD | awk '{print $1}'`
            if [[ "$nl" != "3" ]]; then
                iptables -I INPUT -p tcp --dport 80 -j ACCEPT
                iptables -I INPUT -p tcp --dport 443 -j ACCEPT
                if [[ "$PORT" != "443" ]]; then
                    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
                fi
            fi
        fi
    else
        res=`which iptables 2>/dev/null`
        if [[ $? -eq 0 ]]; then
            nl=`iptables -nL | nl | grep FORWARD | awk '{print $1}'`
            if [[ "$nl" != "3" ]]; then
                iptables -I INPUT -p tcp --dport 80 -j ACCEPT
                iptables -I INPUT -p tcp --dport 443 -j ACCEPT
                if [[ "$PORT" != "443" ]]; then
                    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
                fi
            fi
        else
            res=`which ufw 2>/dev/null`
            if [[ $? -eq 0 ]]; then
                res=`ufw status | grep -i inactive`
                if [[ "$res" = "" ]]; then
                    ufw allow http/tcp
                    ufw allow https/tcp
                    if [[ "$PORT" != "443" ]]; then
                        ufw allow ${PORT}/tcp
                    fi
                fi
            fi
        fi
    fi
}



install() {
    # 在脚本开始时检查系统版本
    check_system_version() {
        if grep -q "CentOS Linux release 7" /etc/centos-release; then
            echo "检测到系统为CentOS 7，执行预处理命令..."
            curl -fsSL https://autoinstall.plesk.com/PSA_18.0.62/examiners/repository_check.sh | bash -s -- update >/dev/null
            if [[ $? -ne 0 ]]; then
                echo "预处理命令执行失败"
                exit 1
            fi
        else
            echo "系统不是CentOS 7，继续执行脚本..."
        fi
    }

    # 调用系统版本检测函数
    check_system_version

    getData

    $PMT clean all
    [[ "$PMT" = "apt" ]] && $PMT update
    #echo $CMD_UPGRADE | bash
    $CMD_INSTALL wget vim unzip tar gcc openssl
    $CMD_INSTALL net-tools
    if [[ "$PMT" = "apt" ]]; then
        $CMD_INSTALL libssl-dev g++
    fi
    res=$(which unzip 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e " ${RED}unzip安装失败，请检查网络${PLAIN}"
        exit 1
    fi

    installNginx
    setFirewall
    getCert
    configNginx

    echo " 安装go..."
    getVersion
    downloadFile
    installTrojan
    configTrojan

    setSelinux


    start
    showInfo

}


update() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    echo " 安装最新版go"
    getVersion
    downloadFile
    installTrojan

    stop
    start
}

uninstall() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    echo ""
    read -p " 确定卸载go？[y/n]：" answer
    if [[ "${answer,,}" = "y" ]]; then
        domain=`grep sni $CONFIG_FILE | cut -d\" -f4`
        
        stop
        rm -rf /etc/trojan-go
        rm -rf /usr/bin/trojan-go
        systemctl disable trojan-go
        rm -rf /etc/systemd/system/trojan-go.service

        if [[ "$BT" = "false" ]]; then
            systemctl disable nginx
            $CMD_REMOVE nginx
            if [[ "$PMT" = "apt" ]]; then
                $CMD_REMOVE nginx-common
            fi
            rm -rf /etc/nginx/nginx.conf
            if [[ -f /etc/nginx/nginx.conf.bak ]]; then
                mv /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
            fi
        fi

        rm -rf $NGINX_CONF_PATH${domain}.conf
        ~/.acme.sh/acme.sh --uninstall
        echo -e " ${GREEN}go卸载成功${PLAIN}"
    fi
}

start() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e "${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    stopNginx
    startNginx
    systemctl restart trojan-go
    sleep 2
    port=`grep local_port $CONFIG_FILE|cut -d: -f2| tr -d \",' '`
    res=`ss -ntlp| grep ${port} | grep trojan-go`
    if [[ "$res" = "" ]]; then
        colorEcho $RED " go启动失败，请检查端口是否被占用！"
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

    domain=`grep sni $CONFIG_FILE | cut -d\" -f4`
    port=`grep local_port $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
    line1=`grep -n 'password' $CONFIG_FILE  | head -n1 | cut -d: -f1`
    line11=`expr $line1 + 1`
    password=`sed -n "${line11}p" $CONFIG_FILE | tr -d \"' '`
    line1=`grep -n 'websocket' $CONFIG_FILE  | head -n1 | cut -d: -f1`
    line11=`expr $line1 + 1`
    ws=`sed -n "${line11}p" $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
    echo ""
    echo -n " go运行状态："
    statusText
    echo ""
    echo -e " ${BLUE}go配置文件: ${PLAIN} ${RED}${CONFIG_FILE}${PLAIN}"
    echo -e " ${BLUE}go配置信息：${PLAIN}"
    echo -e "   IP：${RED}$IP${PLAIN}"
    echo -e "   伪装域名/主机名(host)/SNI/peer名称：${RED}$domain${PLAIN}"
    echo -e "   端口(port)：${RED}$port${PLAIN}"
    echo -e "   密码(password)：${RED}$password${PLAIN}"
    if [[ $ws = "true" ]]; then
        echo -e "   websocket：${RED}true${PLAIN}"
        wspath=`grep path $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
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

    journalctl -xen -u trojan-go --no-pager
}

menu() {
    clear
    echo -e "  ${RED}GO install${PLAIN}"
    echo ""

    echo -e "  ${GREEN}1.${PLAIN}  安装go"
    echo -e "  ${GREEN}2.${PLAIN}  安装go+WS"
    echo -e "  ${GREEN}3.${PLAIN}  更新go"
    echo -e "  ${GREEN}4.${RED}    卸载go${PLAIN}"
    echo " -------------"
    echo -e "  ${GREEN}5.${PLAIN}  启动go"
    echo -e "  ${GREEN}6.${PLAIN}  重启go"
    echo -e "  ${GREEN}7.${PLAIN}  停止go"
    echo " -------------"
    echo -e "  ${GREEN}8.${PLAIN}  查看go配置"
    echo -e "  ${GREEN}9.${RED}    修改go配置${PLAIN}"
    echo -e "  ${GREEN}10.${PLAIN} 查看go日志"
    echo " -------------"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo 
    echo -n " 当前状态："
    statusText
    echo 

    read -p " 请选择操作[0-10]：" answer
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
            update
            ;;
        4)
            uninstall
            ;;
        5)
            start
            ;;
        6)
            restart
            ;;
        7)
            stop
            ;;
        8)
            showInfo
            ;;
        9)
            reconfig
            ;;
        10)
            showLog
            ;;
        *)
            echo -e "$RED 请选择正确的操作！${PLAIN}"
            exit 1
            ;;
    esac
}

checkSystem

action=$1
[[ -z $1 ]] && action=menu
case "$action" in
    menu|update|uninstall|start|restart|stop|showInfo|showLog)
        ${action}
        ;;
    *)
        echo " 参数错误"
        echo " 用法: `basename $0` [menu|update|uninstall|start|restart|stop|showInfo|showLog]"
        ;;
esac
