#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] 请使用root用户运行脚本!" && exit 1

#==================== 公共函数 ====================#

disable_selinux(){
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
}

check_sys(){
    local checkType=$1
    local value=$2
    local release=''
    local systemPackage=''
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
        systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /etc/issue; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /etc/issue; then
        release="ubuntu"
        systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue; then
        release="centos"
        systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /proc/version; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /proc/version; then
        release="ubuntu"
        systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /proc/version; then
        release="centos"
        systemPackage="yum"
    fi

    if [[ "${checkType}" == "sysRelease" ]]; then
        [[ "${value}" == "${release}" ]] && return 0 || return 1
    elif [[ "${checkType}" == "packageManager" ]]; then
        [[ "${value}" == "${systemPackage}" ]] && return 0 || return 1
    fi
}

getversion(){
    if [[ -s /etc/redhat-release ]]; then
        grep -oE "[0-9.]+" /etc/redhat-release
    else
        grep -oE "[0-9.]+" /etc/issue
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
    [ -z "$IP" ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
    [ -z "$IP" ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
    echo "$IP"
}

check_ip(){
    local checkip=$1
    local valid_check=$(echo $checkip|awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{print "yes"}')
    if echo $checkip | grep -E "^[0-9]{1,3}(\.[0-9]{1,3}){3}$" >/dev/null; then
        if [ "${valid_check:-no}" == "yes" ]; then
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
    local filename=$1
    local url=$2
    echo -e "[${green}Info${plain}] 下载 $filename ..."
    wget --no-check-certificate -q -t3 -T60 -O $filename $url
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] 下载 $filename 失败."
        exit 1
    fi
}

error_detect_depends(){
    local command=$1
    local depend=$(echo "$command" | awk '{print $4}')
    echo -e "[${green}Info${plain}] 安装依赖 $depend ..."
    $command > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] 安装 $depend 失败"
        exit 1
    fi
}

#==================== 核心功能 ====================#

restart_services(){
    echo -e "[${green}Info${plain}] 重启 dnsmasq 和 sniproxy ..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart dnsmasq sniproxy
    else
        service dnsmasq restart
        service sniproxy restart
    fi
    echo -e "[${green}Info${plain}] 服务已重启完成."
}

add_keyword_domains(){
    read -p "请输入关键词（如 netflix）: " keyword
    [ -z "$keyword" ] && echo -e "[${red}Error${plain}] 关键词不能为空!" && return
    IP=$(get_ip)
    echo -e "[${green}Info${plain}] 使用公网IP: $IP"

    # dnsmasq
    [ ! -f /etc/dnsmasq.d/custom_netflix.conf ] && touch /etc/dnsmasq.d/custom_netflix.conf
    echo "address=/${keyword}/$IP" >> /etc/dnsmasq.d/custom_netflix.conf
    echo -e "[${green}Info${plain}] Dnsmasq 配置已更新: ${keyword}"

    # sniproxy
    [ ! -f /etc/sniproxy.conf ] && echo -e "table {\n}" > /etc/sniproxy.conf
    sed -i "/table {/a\    .*${keyword}.*" /etc/sniproxy.conf
    echo -e "[${green}Info${plain}] Sniproxy 配置已更新: ${keyword}"

    restart_services
}

install_service(){
    echo -e "[${green}Info${plain}] 安装 Dnsmasq + SNI Proxy ..."
    bash <(curl -s https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh) -i
}

uninstall_service(){
    echo -e "[${yellow}Warning${plain}] 卸载 Dnsmasq + SNI Proxy"
    read -p "是否确认卸载?(y/n, 默认n): " confirm
    [ "$confirm" != "y" ] && echo "取消卸载" && return
    bash <(curl -s https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh) -u
}

#==================== 菜单 ====================#

while true; do
    echo ""
    echo -e "${yellow}==== Dnsmasq + Sniproxy 管理工具 ====${plain}"
    echo "1) 安装服务"
    echo "2) 卸载服务"
    echo "3) 添加关键词匹配域名"
    echo "4) 重启服务"
    echo "0) 退出"
    read -p "请选择操作 [0-4]: " choice
    case $choice in
        1) install_service ;;
        2) uninstall_service ;;
        3) add_keyword_domains ;;
        4) restart_services ;;
        0) echo "退出"; exit 0 ;;
        *) echo -e "[${red}Error${plain}] 无效选择" ;;
    esac
done
