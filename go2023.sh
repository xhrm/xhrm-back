#!/bin/bash
function blue(){
    echo -e "\033[34m\033[01m$1\033[0m"
}
function green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
function red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
function version_lt(){
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1"; 
}

source /etc/os-release
RELEASE=$ID
VERSION=$VERSION_ID
if [ "$RELEASE" == "centos" ]; then
    release="centos"
    systemPackage="yum"
elif [ "$RELEASE" == "debian" ]; then
    release="debian"
    systemPackage="apt-get"
elif [ "$RELEASE" == "ubuntu" ]; then
    release="ubuntu"
    systemPackage="apt-get"
fi
systempwd="/etc/systemd/system/"

function install_trojan(){
    $systemPackage install -y nginx
    if [ ! -d "/etc/nginx/" ]; then
        red "nginx安装有问题，请使用卸载trojan后重新安装"
        exit 1
    fi
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
    #tcp_nopush     on;
    keepalive_timeout  120;
    client_max_body_size 20m;
    #gzip  on;
    server {
        listen       80;
        server_name  $your_domain;
        root /usr/share/nginx/html;
        index index.php index.html index.htm;
    }
}
EOF
    systemctl restart nginx
    sleep 3
    rm -rf /usr/share/nginx/html/*
    cd /usr/share/nginx/html/
    wget https://raw.githubusercontent.com/xhrm/xhrm-back/master/index.zip >/dev/null 2>&1
    unzip index.zip >/dev/null 2>&1
    sleep 5
    if [ ! -d "/usr/src" ]; then
        mkdir /usr/src
    fi
    if [ ! -d "/usr/src/trojan-cert" ]; then
        mkdir /usr/src/trojan-cert /usr/src/trojan-temp
        mkdir /usr/src/trojan-cert/$your_domain
        if [ ! -d "/usr/src/trojan-cert/$your_domain" ]; then
            red "不存在/usr/src/trojan-cert/$your_domain目录"
            exit 1
        fi
        curl https://get.acme.sh | sh -s email=test@$your_domain
        source ~/.bashrc
        ~/.acme.sh/acme.sh  --upgrade  --auto-upgrade
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh  --issue  -d $your_domain  --nginx
        if test -s /root/.acme.sh/$your_domain/fullchain.cer; then
            cert_success="1"
        fi
    elif [ -f "/usr/src/trojan-cert/$your_domain/fullchain.cer" ]; then
        cd /usr/src/trojan-cert/$your_domain
        create_time=`stat -c %Y fullchain.cer`
        now_time=`date +%s`
        minus=$(($now_time - $create_time ))
        if [  $minus -gt 5184000 ]; then
            curl https://get.acme.sh | sh -s email=test@$your_domain
            source ~/.bashrc
            ~/.acme.sh/acme.sh  --upgrade  --auto-upgrade
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh  --issue  -d $your_domain  --nginx
            if test -s /root/.acme.sh/$your_domain/fullchain.cer; then
                cert_success="1"
            fi
        else 
            green "检测到域名$your_domain证书存在且未超过60天，无需重新申请"
            cert_success="1"
        fi        
    else 
	mkdir /usr/src/trojan-cert/$your_domain
        curl https://get.acme.sh | sh -s email=test@$your_domain
        source ~/.bashrc
        ~/.acme.sh/acme.sh  --upgrade  --auto-upgrade
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh  --issue  -d $your_domain  --nginx
        if test -s /root/.acme.sh/$your_domain/fullchain.cer; then
            cert_success="1"
        fi
    fi
    
    if [ "$cert_success" == "1" ]; then
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
    #tcp_nopush     on;
    keepalive_timeout  120;
    client_max_body_size 20m;
    #gzip  on;
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
        systemctl enable nginx
        cd /usr/src
        wget https://api.github.com/repos/fregie/trojan-go/releases/latest >/dev/null 2>&1
        latest_version=`grep tag_name latest| awk -F '[:,"v]' '{print $6}'`
        rm -f latest
        green "开始下载最新版trojan amd64"
        wget https://github.com/fregie/trojan-go/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.zip
        tar xf trojan-go-linux-amd64.zip >/dev/null 2>&1
        rm -f trojan-go-linux-amd64.zip
        green "请设置trojan密码，建议不要出现特殊字符"
        read -p "请输入密码 :" trojan_passwd
        #trojan_passwd=$(cat /dev/urandom | head -1 | md5sum | head -c 8)
         rm -rf /usr/src/trojan/server.json
         cat > /usr/src/trojan/server.json <<-EOF
{
	"run_type": "server",
	"local_addr": "0.0.0.0",
	"local_port": 443,
	"remote_addr": "127.0.0.1",
	"remote_port": 80,
	"log_level": 1,
	"log_file": "",
	"password": [
		"$trojan_passwd"
	],
	"disable_http_check": false,
	"udp_timeout": 60,
	"ssl": {
		"verify": true,
		"verify_hostname": true,
		"cert": "/usr/src/trojan-cert/$your_domain/fullchain.cer",
		"key": "/usr/src/trojan-cert/$your_domain/private.key",
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
		"fingerprint": "chrome"
	},
	"tcp": {
		"no_delay": true,
		"keep_alive": true,
		"prefer_ipv4": false
	},
	"mux": {
		"enabled": false,
		"concurrency": 8,
		"idle_timeout": 60
	},
	"router": {
		"enabled": false,
		"bypass": [],
		"proxy": [],
		"block": [],
		"default_policy": "proxy",
		"domain_strategy": "as_is",
		"geoip": "/usr/src/trojan/geoip.dat",
		"geosite": "/usr/src/trojan/geosite.dat"
	},
	"websocket": {
		"enabled": false,
		"path": "",
		"host": ""
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
        rm -rf /usr/src/trojan-temp/
        rm -f /usr/src/trojan-cli.zip
        trojan_path=$(cat /dev/urandom | head -1 | md5sum | head -c 16)
        #mkdir /usr/share/nginx/html/${trojan_path}
        #mv /usr/src/trojan-cli/trojan-cli.zip /usr/share/nginx/html/${trojan_path}/	
        cat > ${systempwd}trojan-go.service <<-EOF
[Unit]  
Description=trojan  
After=network.target  
   
[Service]  
Type=simple  
PIDFile=/usr/src/trojan/trojan/trojan-go.pid
ExecStart=/usr/src/trojan/trojan -c "/usr/src/trojan/server.json"  
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=infinity
Restart=on-failure
RestartSec=1s
   
[Install]  
WantedBy=multi-user.target
EOF

        chmod +x ${systempwd}trojan-go.service
        systemctl enable trojan-go.service
        cd /root
        ~/.acme.sh/acme.sh  --installcert  -d  $your_domain   \
            --key-file   /usr/src/trojan-cert/$your_domain/private.key \
            --fullchain-file  /usr/src/trojan-cert/$your_domain/fullchain.cer \
            --reloadcmd  "systemctl restart trojan-go"	
        green "=========================================================================="
        green "                         Trojan已安装完成"
        green "=========================================================================="
    else
        red "==================================="
        red "https证书没有申请成功，本次安装失败"
        red "==================================="
    fi
}
function preinstall_check(){

    nginx_status=`ps -aux | grep "nginx: worker" |grep -v "grep"`
    if [ -n "$nginx_status" ]; then
        systemctl stop nginx
    fi
    $systemPackage -y install net-tools socat >/dev/null 2>&1
    Port80=`netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80`
    Port443=`netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 443`
    if [ -n "$Port80" ]; then
        process80=`netstat -tlpn | awk -F '[: ]+' '$5=="80"{print $9}'`
        red "==========================================================="
        red "检测到80端口被占用，占用进程为：${process80}，本次安装结束"
        red "==========================================================="
        exit 1
    fi
    if [ -n "$Port443" ]; then
        process443=`netstat -tlpn | awk -F '[: ]+' '$5=="443"{print $9}'`
        red "============================================================="
        red "检测到443端口被占用，占用进程为：${process443}，本次安装结束"
        red "============================================================="
        exit 1
    fi
    if [ -f "/etc/selinux/config" ]; then
        CHECK=$(grep SELINUX= /etc/selinux/config | grep -v "#")
        if [ "$CHECK" == "SELINUX=enforcing" ]; then
            green "$(date +"%Y-%m-%d %H:%M:%S") - SELinux状态非disabled,关闭SELinux."
            setenforce 0
            sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
            #loggreen "SELinux is not disabled, add port 80/443 to SELinux rules."
            #loggreen "==== Install semanage"
            #logcmd "yum install -y policycoreutils-python"
            #semanage port -a -t http_port_t -p tcp 80
            #semanage port -a -t http_port_t -p tcp 443
            #semanage port -a -t http_port_t -p tcp 37212
            #semanage port -a -t http_port_t -p tcp 37213
        elif [ "$CHECK" == "SELINUX=permissive" ]; then
            green "$(date +"%Y-%m-%d %H:%M:%S") - SELinux状态非disabled,关闭SELinux."
            setenforce 0
            sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
        fi
    fi
    if [ "$release" == "centos" ]; then
        if  [ -n "$(grep ' 6\.' /etc/redhat-release)" ] ;then
        red "==============="
        red "当前系统不受支持"
        red "==============="
        exit
        fi
        if  [ -n "$(grep ' 5\.' /etc/redhat-release)" ] ;then
        red "==============="
        red "当前系统不受支持"
        red "==============="
        exit
        fi
        firewall_status=`systemctl status firewalld | grep "Active: active"`
        if [ -n "$firewall_status" ]; then
            green "检测到firewalld开启状态，添加放行80/443端口规则"
            firewall-cmd --zone=public --add-port=80/tcp --permanent
            firewall-cmd --zone=public --add-port=443/tcp --permanent
            firewall-cmd --reload
        fi
        rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm --force --nodeps
    elif [ "$release" == "ubuntu" ]; then
        if  [ -n "$(grep ' 14\.' /etc/os-release)" ] ;then
        red "==============="
        red "当前系统不受支持"
        red "==============="
        exit
        fi
        if  [ -n "$(grep ' 12\.' /etc/os-release)" ] ;then
        red "==============="
        red "当前系统不受支持"
        red "==============="
        exit
        fi
        ufw_status=`systemctl status ufw | grep "Active: active"`
        if [ -n "$ufw_status" ]; then
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw reload
        fi
        apt-get update
    elif [ "$release" == "debian" ]; then
        ufw_status=`systemctl status ufw | grep "Active: active"`
        if [ -n "$ufw_status" ]; then
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw reload
        fi
        apt-get update
    fi
    $systemPackage -y install  wget unzip zip curl tar >/dev/null 2>&1
    green "======================="
    blue "请输入绑定到云服务器的域名"
    green "======================="
    read your_domain
    real_addr=`ping ${your_domain} -c 1 | sed '1{s/[^(]*(//;s/).*//;q}'`
    local_addr=`curl ipv4.icanhazip.com`
    if [ $real_addr == $local_addr ] ; then
        green "=========================================="
        green "       域名解析正常，开始安装trojan"
        green "=========================================="
        sleep 1s
        install_trojan
    else
        red "===================================="
        red "域名解析地址与云服务器IP地址不一致"
        red "若你确认解析成功你可强制脚本继续运行"
        red "===================================="
        read -p "是否强制运行 ?请输入 [Y/n] :" yn
        [ -z "${yn}" ] && yn="y"
        if [[ $yn == [Yy] ]]; then
            green "强制继续运行脚本"
            sleep 1s
            install_trojan
        else
            exit 1
        fi
    fi
}



start_menu(){
    clear
    green " ======================================="
    green " 介绍: 一键安装trojan-go     "
    green " 系统: centos7+/debian9+/ubuntu16.04+"
    green " 作者: xhrm           "
    blue " 注意:"
    red " *1. 不要在任何生产环境使用此脚本"
    red " *2. 不要占用80和443端口"
    red " *3. 若第二次使用脚本，请先执行卸载trojan"
    green " ======================================="
    echo
    green " 1. 安装"
    blue " 0. 退出脚本"
    echo
    read -p "请输入数字 :" num
    case "$num" in
    1)
    remove_trojan 
    ;;
    0)
    exit 1
    ;;
    *)
    clear
    red "请输入正确数字"
    sleep 1s
    start_menu
    ;;
    esac
}

start_menu
