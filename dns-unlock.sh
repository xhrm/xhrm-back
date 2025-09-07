#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] 请使用root用户来执行脚本!" && exit 1

# ----------------- 基础函数 -----------------
disable_selinux(){
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
        echo -e "[${green}Info${plain}] SELinux 已禁用"
    fi
}

check_sys(){
    local checkType=$1
    local value=$2
    local release=''
    local systemPackage=''

    if [[ -f /etc/redhat-release ]]; then
        release="centos"; systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /etc/issue; then
        release="debian"; systemPackage="apt"
    elif grep -Eqi "ubuntu" /etc/issue; then
        release="ubuntu"; systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue; then
        release="centos"; systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /proc/version; then
        release="debian"; systemPackage="apt"
    elif grep -Eqi "ubuntu" /proc/version; then
        release="ubuntu"; systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /proc/version; then
        release="centos"; systemPackage="yum"
    fi

    if [[ "${checkType}" == "sysRelease" ]]; then
        [[ "${value}" == "${release}" ]] && return 0 || return 1
    elif [[ "${checkType}" == "packageManager" ]]; then
        [[ "${value}" == "${systemPackage}" ]] && return 0 || return 1
    fi
}

getversion(){
    if [[ -s /etc/redhat-release ]]; then
        grep -oE  "[0-9.]+" /etc/redhat-release
    else
        grep -oE  "[0-9.]+" /etc/issue
    fi
}

centosversion(){
    if check_sys sysRelease centos; then
        local code=$1
        local version="$(getversion)"
        local main_ver=${version%%.*}
        [[ "$main_ver" == "$code" ]] && return 0 || return 1
    else
        return 1
    fi
}

get_ip(){
    local IP=$( ip addr | egrep -o '[0-9]{1,3}(\.[0-9]{1,3}){3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
    echo ${IP}
}

check_ip(){
    local checkip=$1
    local valid_check=$(echo $checkip|awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{print "yes"}')
    if echo $checkip|grep -E "^[0-9]{1,3}(\.[0-9]{1,3}){3}$" >/dev/null; then
        if [ ${valid_check:-no} == "yes" ]; then
            return 0
        else
            echo -e "[${red}Error${plain}] IP $checkip not available!"
            return 1
        fi
    else
        echo -e "[${red}Error${plain}] IP format error!"
        return 1
    fi
}

download(){
    local filename=${1}
    echo -e "[${green}Info${plain}] ${filename} 下载中..."
    wget --no-check-certificate -q -t3 -T60 -O ${1} ${2}
    [[ $? -ne 0 ]] && echo -e "[${red}Error${plain}] 下载 ${filename} 失败." && exit 1
}

error_detect_depends(){
    local command=$1
    local depend=`echo "${command}" | awk '{print $4}'`
    echo -e "[${green}Info${plain}] 安装依赖 ${depend} ..."
    ${command} > /dev/null 2>&1
    [[ $? -ne 0 ]] && echo -e "[${red}Error${plain}] 安装 ${depend} 失败" && exit 1
}

config_firewall(){
    local ports="53 80 443"
    if centosversion 6; then
        /etc/init.d/iptables status >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            for port in ${ports}; do
                iptables -L -n | grep -i ${port} >/dev/null 2>&1 || iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${port} -j ACCEPT
                [[ ${port} == "53" ]] && iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${port} -j ACCEPT
            done
            /etc/init.d/iptables save
            /etc/init.d/iptables restart
        fi
    else
        systemctl status firewalld >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            default_zone=$(firewall-cmd --get-default-zone)
            for port in ${ports}; do
                firewall-cmd --permanent --zone=${default_zone} --add-port=${port}/tcp
                [[ ${port} == "53" ]] && firewall-cmd --permanent --zone=${default_zone} --add-port=${port}/udp
            done
            firewall-cmd --reload
        fi
    fi
}

install_dependencies(){
    echo "安装依赖软件..."
    if check_sys packageManager yum; then
        yum install -y epel-release yum-utils >/dev/null 2>&1
        yum_depends=( curl gettext-devel libev-devel pcre-devel perl udns-devel )
        for depend in ${yum_depends[@]}; do error_detect_depends "yum -y install ${depend}"; done
    elif check_sys packageManager apt; then
        apt-get update
        apt_depends=( curl gettext libev-dev libpcre3-dev libudns-dev )
        for depend in ${apt_depends[@]}; do error_detect_depends "apt-get -y install ${depend}"; done
    fi
}

# ----------------- 安装/卸载逻辑 -----------------
install_dnsmasq(){
    netstat -a -n -p | grep LISTEN | grep -P "\d+\.\d+\.\d+\.\d+:53\s+" >/dev/null && echo -e "[${red}Error${plain}] 端口53已被占用" && exit 1
    echo "安装 Dnsmasq..."
    install_dependencies
    if check_sys packageManager yum; then
        yum install -y dnsmasq >/dev/null 2>&1
    elif check_sys packageManager apt; then
        apt-get install -y dnsmasq >/dev/null 2>&1
    fi
    download /etc/dnsmasq.d/custom_netflix.conf https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/dnsmasq.conf
    [ ! -f /usr/sbin/dnsmasq ] && echo -e "[${red}Error${plain}] 安装dnsmasq失败" && exit 1
    systemctl enable dnsmasq >/dev/null 2>&1
    systemctl restart dnsmasq >/dev/null 2>&1
    echo -e "[${green}Info${plain}] Dnsmasq 安装完成"
}

install_sniproxy(){
    for port in 80 443; do
        netstat -a -n -p | grep LISTEN | grep -P "\d+\.\d+\.\d+\.\d+:${port}\s+" >/dev/null && echo -e "[${red}Error${plain}] 端口${port}已被占用" && exit 1
    done
    install_dependencies
    echo "安装 SNI Proxy..."
    if check_sys packageManager yum; then
        yum install -y sniproxy >/dev/null 2>&1
    elif check_sys packageManager apt; then
        apt-get install -y sniproxy >/dev/null 2>&1
    fi
    download /etc/sniproxy.conf https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/sniproxy.conf
    systemctl enable sniproxy >/dev/null 2>&1
    systemctl restart sniproxy >/dev/null 2>&1
    echo -e "[${green}Info${plain}] SNI Proxy 安装完成"
}

install_all(){
    disable_selinux
    config_firewall
    install_dnsmasq
    install_sniproxy
}

undnsmasq(){
    echo -e "[${green}Info${plain}] 卸载 Dnsmasq..."
    systemctl stop dnsmasq >/dev/null 2>&1
    systemctl disable dnsmasq >/dev/null 2>&1
    if check_sys packageManager yum; then
        yum remove -y dnsmasq >/dev/null 2>&1
    elif check_sys packageManager apt; then
        apt-get remove -y dnsmasq dnsmasq-base >/dev/null 2>&1
    fi
    rm -f /etc/dnsmasq.d/custom_netflix.conf
    echo -e "[${green}Info${plain}] Dnsmasq 卸载完成"
}

unsniproxy(){
    echo -e "[${green}Info${plain}] 卸载 SNI Proxy..."
    systemctl stop sniproxy >/dev/null 2>&1
    systemctl disable sniproxy >/dev/null 2>&1
    if check_sys packageManager yum; then
        yum remove -y sniproxy >/dev/null 2>&1
    elif check_sys packageManager apt; then
        apt-get remove -y sniproxy >/dev/null 2>&1
    fi
    rm -f /etc/sniproxy.conf
    echo -e "[${green}Info${plain}] SNI Proxy 卸载完成"
}

# ----------------- 菜单 -----------------
hello(){
    echo ""
    echo -e "${yellow}Dnsmasq + SNI Proxy 自助安装脚本${plain}"
    echo ""
}

show_menu(){
    while true; do
        clear
        hello
        echo "========================================"
        echo " 1) 安装服务"
        echo " 2) 卸载服务"
        echo " 3) 更新/重启服务"
        echo " 4) 退出"
        echo "========================================"
        read -p "请输入选择 [1-4]: " menu_choice
        case $menu_choice in
            1)
                install_all
                echo -e "${green}安装完成!${plain}"
                read -p "按回车返回菜单..." ;;
            2)
                confirm && undnsmasq && unsniproxy
                echo -e "${green}卸载完成!${plain}"
                read -p "按回车返回菜单..." ;;
            3)
                echo -e "${green}正在重启 Dnsmasq 和 SNI Proxy...${plain}"
                systemctl restart dnsmasq sniproxy >/dev/null 2>&1
                echo -e "${green}重启完成!${plain}"
                read -p "按回车返回菜单..." ;;
            4) exit 0 ;;
            *) echo "无效选择"; sleep 2 ;;
        esac
    done
}

# ----------------- 主入口 -----------------
show_menu
