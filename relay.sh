#!/bin/bash

CONFIG="/etc/nginx/stream.d/forward.conf"
NGINX_CONF="/etc/nginx/nginx.conf"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"


check_root(){

    if [ "$EUID" != "0" ]; then
        echo -e "${RED}请使用root运行${NC}"
        exit 1
    fi

}


detect_system(){

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo "无法识别系统"
        exit 1
    fi


    case "$OS" in

        centos|rhel|rocky|almalinux|fedora)
            PM="yum"
            ;;

        debian|ubuntu)
            PM="apt"
            ;;

        *)
            echo "不支持系统:$OS"
            exit 1
            ;;

    esac

}



install_nginx(){


echo -e "${BLUE}检查 nginx...${NC}"


if command -v nginx >/dev/null 2>&1; then

    echo -e "${GREEN}检测到 nginx${NC}"

else


    echo -e "${BLUE}安装 nginx${NC}"


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


fi


}



install_stream_module(){


echo -e "${BLUE}检查stream模块${NC}"


# 静态模块

if nginx -V 2>&1 | grep -q -- "--with-stream"; then

    echo -e "${GREEN}stream静态模块存在${NC}"
    return

fi



# 动态模块文件

MODULE=""



for f in \
/usr/lib/nginx/modules/ngx_stream_module.so \
/usr/lib64/nginx/modules/ngx_stream_module.so

do

    if [ -f "$f" ]; then
        MODULE="$f"
        break
    fi

done



if [ -z "$MODULE" ]; then


    echo -e "${YELLOW}安装stream模块${NC}"


    case "$PM" in


    apt)

        apt update

        apt install -y libnginx-mod-stream


        ;;


    yum)

        yum install -y nginx-mod-stream


        ;;


    esac



    for f in \
    /usr/lib/nginx/modules/ngx_stream_module.so \
    /usr/lib64/nginx/modules/ngx_stream_module.so

    do

        if [ -f "$f" ]; then
            MODULE="$f"
            break
        fi

    done


fi



if [ -z "$MODULE" ]; then

    echo -e "${RED}未找到stream模块${NC}"
    nginx -V
    exit 1

fi



# 动态模块加载

if ! nginx -T 2>/dev/null | grep -q ngx_stream_module.so; then


    echo -e "${BLUE}加载stream动态模块${NC}"


    sed -i "1iload_module modules/ngx_stream_module.so;" \
    "$NGINX_CONF"


fi



echo -e "${GREEN}stream模块正常${NC}"


}



config_nginx(){


mkdir -p /etc/nginx/stream.d



if ! grep -q "stream.d/*.conf" "$NGINX_CONF"; then


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



echo -e "${BLUE}测试nginx配置${NC}"


if nginx -t; then


    systemctl enable nginx >/dev/null 2>&1


    systemctl restart nginx


    echo
    echo -e "${GREEN}部署成功${NC}"
    echo "TCP443 ---> ${IP}:443"


else


    echo -e "${RED}nginx配置失败${NC}"

    nginx -t

fi


}



status(){


echo

echo "==========状态=========="



if systemctl is-active nginx >/dev/null 2>&1; then

echo -e "nginx:${GREEN}运行${NC}"

else

echo -e "nginx:${RED}停止${NC}"

fi



if [ -f "$CONFIG" ]; then

grep "server .*:443" "$CONFIG"

fi


echo "========================"

}



main(){


check_root

detect_system

install_nginx

install_stream_module

config_nginx



while true

do

echo
echo "1.设置转发"
echo "2.查看状态"
echo "0.退出"


read -p "请选择:" CH


case "$CH" in

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
echo "输入错误"

;;

esac


done


}



main
