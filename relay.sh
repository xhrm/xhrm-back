#!/bin/bash

CONFIG="/etc/nginx/stream.d/forward.conf"
NGINX_CONF="/etc/nginx/nginx.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    else
        echo -e "${RED}无法识别系统${NC}"
        exit 1
    fi


    case "$OS" in

        centos|rhel|rocky|almalinux)
            PM="yum"
            ;;

        debian|ubuntu)
            PM="apt"
            ;;

        *)
            echo -e "${RED}不支持系统:$OS${NC}"
            exit 1
            ;;

    esac
}


check_stream(){

    if nginx -V 2>&1 | grep -q -- "--with-stream"; then
        return 0
    fi

    return 1
}



install_nginx(){


echo -e "${BLUE}安装 nginx...${NC}"


if command -v nginx >/dev/null; then

    if check_stream; then

        echo -e "${GREEN}已有 nginx stream 模块${NC}"
        return

    fi

fi



case "$PM" in


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



apt)


apt update

apt install -y nginx


;;

esac



if ! check_stream; then

    echo -e "${YELLOW}当前 nginx 无 stream 模块，安装扩展${NC}"


    case "$PM" in

    yum)
        yum install -y nginx-mod-stream
        ;;

    apt)

        apt install -y nginx-extras || apt install -y nginx-full

        ;;

    esac

fi



if ! check_stream; then

    echo -e "${RED}nginx stream 模块安装失败${NC}"
    nginx -V
    exit 1

fi


echo -e "${GREEN}nginx stream 模块正常${NC}"

}



config_stream(){


mkdir -p /etc/nginx/stream.d



if ! grep -q "stream.d/\*.conf" "$NGINX_CONF"; then


cat >> "$NGINX_CONF" <<EOF


stream {

    include /etc/nginx/stream.d/*.conf;

}

EOF


fi


}



set_forward(){


read -p "请输入目标服务器IP: " IP


if ! [[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

    echo -e "${RED}IP格式错误${NC}"
    exit 1

fi



cat > "$CONFIG" <<EOF

upstream backend {

    server ${IP}:443;

}


server {

    listen 443 reuseport;


    proxy_pass backend;

    proxy_connect_timeout 10s;

    proxy_timeout 1h;

    proxy_socket_keepalive on;

}

EOF



echo

echo -e "${BLUE}检测 nginx 配置...${NC}"


if nginx -t; then


    systemctl enable nginx >/dev/null 2>&1

    systemctl restart nginx


    if systemctl is-active nginx >/dev/null; then

        echo
        echo -e "${GREEN}部署成功${NC}"
        echo -e "转发目标: ${IP}:443"

    else

        echo -e "${RED}nginx启动失败${NC}"

    fi


else

    echo -e "${RED}nginx配置错误${NC}"
    exit 1

fi


}



status(){


echo

echo "========== Nginx TCP转发状态 =========="


if systemctl is-active nginx >/dev/null; then

echo -e "Nginx: ${GREEN}运行中${NC}"

else

echo -e "Nginx: ${RED}停止${NC}"

fi


if [ -f "$CONFIG" ]; then

grep "server .*:443" "$CONFIG"

fi


echo "======================================"

}



main(){


check_root

detect_system

install_nginx

config_stream


while true
do

echo
echo "1. 设置转发目标"
echo "2. 查看状态"
echo "0. 退出"

read -p "请选择: " C


case "$C" in

1)
set_forward
;;

2)
status
;;

0)
exit
;;

*)
echo "错误"

;;

esac


done


}


main
