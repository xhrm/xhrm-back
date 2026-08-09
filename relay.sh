#!/bin/bash

CONFIG="/etc/nginx/stream.d/trojan.conf"
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
            echo "不支持系统: $OS"
            exit 1
            ;;

    esac

}



install_nginx(){

    if command -v nginx >/dev/null 2>&1; then

        echo -e "${GREEN}检测到 nginx${NC}"
        return

    fi



    echo -e "${BLUE}安装 nginx${NC}"


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


echo -e "${BLUE}检查 nginx stream 模块${NC}"


# 已编译模块

if nginx -V 2>&1 | grep -q "stream"; then

    echo -e "${GREEN}stream编译支持${NC}"

fi



MODULE=""


for m in \
/usr/lib/nginx/modules/ngx_stream_module.so \
/usr/lib64/nginx/modules/ngx_stream_module.so

do

    if [ -f "$m" ]; then

        MODULE="$m"
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



    for m in \
    /usr/lib/nginx/modules/ngx_stream_module.so \
    /usr/lib64/nginx/modules/ngx_stream_module.so

    do

        if [ -f "$m" ]; then

            MODULE="$m"
            break

        fi

    done


fi



if [ -z "$MODULE" ]; then

    echo -e "${RED}找不到stream模块${NC}"
    nginx -V
    exit 1

fi



# 加载动态模块

if ! grep -q "ngx_stream_module.so" "$NGINX_CONF"; then


    echo -e "${BLUE}加载stream模块${NC}"


    sed -i "1iload_module modules/ngx_stream_module.so;" \
    "$NGINX_CONF"


fi


echo -e "${GREEN}stream模块正常${NC}"


}



add_stream_conf(){


mkdir -p /etc/nginx/stream.d



if ! grep -q "/etc/nginx/stream.d" "$NGINX_CONF"; then


cat >> "$NGINX_CONF" <<EOF


stream {

    include /etc/nginx/stream.d/*.conf;

}

EOF


fi


}



set_trojan_forward(){


read -p "请输入Trojan服务器IP: " IP


if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

    echo -e "${RED}IP格式错误${NC}"
    return

fi



cat > "${CONFIG}.tmp" <<EOF

upstream trojan_backend {


    server ${IP}:443;


}


server {


    listen 443 reuseport fastopen=1024;


    proxy_pass trojan_backend;


    proxy_connect_timeout 10s;


    proxy_timeout 24h;


    proxy_socket_keepalive on;


}

EOF



mv "${CONFIG}.tmp" "$CONFIG"



echo -e "${BLUE}检测nginx配置${NC}"


if nginx -t; then


    systemctl enable nginx >/dev/null 2>&1

    systemctl restart nginx



    if systemctl is-active nginx >/dev/null 2>&1; then


        echo
        echo -e "${GREEN}Trojan中转部署成功${NC}"
        echo "本机443 ---> ${IP}:443"


    else

        echo -e "${RED}nginx启动失败${NC}"

    fi



else


    echo -e "${RED}配置错误，未启动${NC}"

    nginx -t


fi



}



show_status(){


echo

echo "========== Trojan中转状态 =========="



if systemctl is-active nginx >/dev/null 2>&1; then

echo -e "nginx: ${GREEN}运行${NC}"

else

echo -e "nginx: ${RED}停止${NC}"

fi



if [ -f "$CONFIG" ]; then

echo "目标:"
grep "server .*:443" "$CONFIG"

fi


echo "================================="

}



main(){


check_root

detect_system

install_nginx

install_stream

add_stream_conf



while true

do

echo

echo "1.设置Trojan转发"

echo "2.查看状态"

echo "0.退出"


read -p "请选择: " C


case "$C" in


1)
set_trojan_forward
;;


2)
show_status
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
