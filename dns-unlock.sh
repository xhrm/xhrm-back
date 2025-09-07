#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] 请使用root用户来执行脚本!" && exit 1

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
        [[ ${valid_check:-no} == "yes" ]] && return 0 || { echo -e "[${red}Error${plain}] IP $checkip not available!"; return 1; }
    else
        echo -e "[${red}Error${plain}] IP format error!" 
        return 1
    fi
}

download(){
    local filename=${1}
    echo -e "[${green}Info${plain}] ${filename} download configuration now..."
    wget --no-check-certificate -q -t3 -T60 -O ${1} ${2}
    [[ $? -ne 0 ]] && { echo -e "[${red}Error${plain}] Download ${filename} failed."; exit 1; }
}

error_detect_depends(){
    local command=$1
    local depend=`echo "${command}" | awk '{print $4}'`
    echo -e "[${green}Info${plain}] Starting to install package ${depend}"
    ${command} > /dev/null 2>&1
    [[ $? -ne 0 ]] && { echo -e "[${red}Error${plain}] Failed to install ${red}${depend}${plain}"; exit 1; }
}

config_firewall(){
    if centosversion 6; then
        /etc/init.d/iptables status > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            for port in ${ports}; do
                iptables -L -n | grep -i ${port} > /dev/null 2>&1
                if [ $? -ne 0 ]; then
                    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${port} -j ACCEPT
                    [[ ${port} == "53" ]] && iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${port} -j ACCEPT
                fi
            done
            /etc/init.d/iptables save
            /etc/init.d/iptables restart
        else
            echo -e "[${yellow}Warning${plain}] iptables not running, manually enable port ${ports}."
        fi
    else
        systemctl status firewalld > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            default_zone=$(firewall-cmd --get-default-zone)
            for port in ${ports}; do
                firewall-cmd --permanent --zone=${default_zone} --add-port=${port}/tcp
                [[ ${port} == "53" ]] && firewall-cmd --permanent --zone=${default_zone} --add-port=${port}/udp
                firewall-cmd --reload
            done
        else
            echo -e "[${yellow}Warning${plain}] firewalld not running, manually enable port ${ports}."
        fi
    fi
}

install_dependencies(){
    echo "安装依赖软件..."
    if check_sys packageManager yum; then
        echo -e "[${green}Info${plain}] Checking the EPEL repository..."
        [[ ! -f /etc/yum.repos.d/epel.repo ]] && yum install -y epel-release > /dev/null 2>&1
        [[ ! -f /etc/yum.repos.d/epel.repo ]] && echo -e "[${red}Error${plain}] Install EPEL failed." && exit 1
        [[ ! "$(command -v yum-config-manager)" ]] && yum install -y yum-utils > /dev/null 2>&1
        [ x"$(yum repolist epel | grep -w epel | awk '{print $NF}')" != x"enabled" ] && yum-config-manager --enable epel > /dev/null 2>&1
        if [[ ${fastmode} = "1" ]]; then
            yum_depends=(curl gettext-devel libev-devel pcre-devel perl udns-devel)
        else
            yum_depends=(autoconf automake curl gettext-devel libev-devel pcre-devel perl udns-devel)
        fi
        for depend in ${yum_depends[@]}; do error_detect_depends "yum -y install ${depend}"; done
        if [[ ${fastmode} = "0" ]]; then
            centosversion 6 && { error_detect_depends "yum -y groupinstall development"; error_detect_depends "yum -y install centos-release-scl"; error_detect_depends "yum -y install devtoolset-6-gcc-c++"; } || { yum config-manager --set-enabled powertools; error_detect_depends "yum -y groupinstall development"; }
        fi
    elif check_sys packageManager apt; then
        [[ ${fastmode} = "1" ]] && apt_depends=(curl gettext libev-dev libpcre3-dev libudns-dev) || apt_depends=(autotools-dev cdbs curl gettext libev-dev libpcre3-dev libudns-dev autoconf devscripts)
        apt-get -y update
        for depend in ${apt_depends[@]}; do error_detect_depends "apt-get -y install ${depend}"; done
        [[ ${fastmode} = "0" ]] && error_detect_depends "apt-get -y install build-essential"
    fi
}

compile_dnsmasq(){
    if check_sys packageManager yum; then
        error_detect_depends "yum -y install epel-release make gcc-c++ nettle-devel gettext libidn-devel libnetfilter_conntrack-devel dbus-devel"
    elif check_sys packageManager apt; then
        error_detect_depends "apt -y install make gcc g++ pkg-config nettle-dev gettext libidn11-dev libnetfilter-conntrack-dev libdbus-1-dev"
    fi
    [[ -e /tmp/dnsmasq-2.91 ]] && rm -rf /tmp/dnsmasq-2.91
    cd /tmp/
    download dnsmasq-2.91.tar.gz https://thekelleys.org.uk/dnsmasq/dnsmasq-2.91.tar.gz
    tar -zxf dnsmasq-2.91.tar.gz
    cd dnsmasq-2.91
    make all-i18n V=s COPTS='-DHAVE_DNSSEC -DHAVE_IDN -DHAVE_CONNTRACK -DHAVE_DBUS'
    [[ $? -ne 0 ]] && echo -e "[${red}Error${plain}] Compile dnsmasq failed!" && exit 1
    make install
}

install_dnsmasq(){
    compile_dnsmasq
    mkdir -p /etc/dnsmasq.d
    [[ ! -f /usr/local/sbin/dnsmasq ]] && echo -e "[${red}Error${plain}] dnsmasq not installed!" && exit 1
    echo -e "[${green}Info${plain}] dnsmasq installed successfully!"
}

install_sniproxy(){
    install_dependencies
    cd /tmp/
    download sniproxy-0.6.0.tar.gz https://github.com/dlundquist/sniproxy/archive/refs/tags/v0.6.0.tar.gz
    tar -zxf sniproxy-0.6.0.tar.gz
    cd sniproxy-0.6.0
    ./configure
    make
    make install
    [[ ! -f /usr/local/sbin/sniproxy ]] && echo -e "[${red}Error${plain}] sniproxy not installed!" && exit 1
    echo -e "[${green}Info${plain}] sniproxy installed successfully!"
}

undnsmasq(){
    [[ -f /usr/local/sbin/dnsmasq ]] && rm -f /usr/local/sbin/dnsmasq
    [[ -d /etc/dnsmasq.d ]] && rm -rf /etc/dnsmasq.d
    echo -e "[${green}Info${plain}] dnsmasq uninstalled."
}

unsniproxy(){
    [[ -f /usr/local/sbin/sniproxy ]] && rm -f /usr/local/sbin/sniproxy
    echo -e "[${green}Info${plain}] sniproxy uninstalled."
}

hello(){
    echo ""
    echo -e "${yellow}Dnsmasq + SNI Proxy自助安装脚本${plain}"
    echo -e "${yellow}支持系统:  CentOS 6+, Debian8+, Ubuntu16+${plain}"
    echo ""
}

confirm(){
    echo -e "${yellow}是否继续执行?(n:取消/y:继续)${plain}"
    read -e -p "(默认:取消): " selection
    [ -z "${selection}" ] && selection="n"
    [[ ${selection} != "y" ]] && exit 0
}

menu(){
    hello
    echo "请选择操作:"
    echo "1. 安装 Dnsmasq + SNI Proxy"
    echo "2. 快速安装 Dnsmasq + SNI Proxy"
    echo "3. 仅安装 Dnsmasq"
    echo "4. 快速安装 Dnsmasq"
    echo "5. 仅安装 SNI Proxy"
    echo "6. 快速安装 SNI Proxy"
    echo "7. 卸载 Dnsmasq + SNI Proxy"
    echo "8. 卸载 Dnsmasq"
    echo "9. 卸载 SNI Proxy"
    echo "10. 重启系统"
    echo "0. 退出"
    read -e -p "请输入数字选择: " choice
    case $choice in
        1) fastmode=0; install_dnsmasq; install_sniproxy ;;
        2) fastmode=1; install_dnsmasq; install_sniproxy ;;
        3) fastmode=0; install_dnsmasq ;;
        4) fastmode=1; install_dnsmasq ;;
        5) fastmode=0; install_sniproxy ;;
        6) fastmode=1; install_sniproxy ;;
        7) confirm; undnsmasq; unsniproxy ;;
        8) confirm; undnsmasq ;;
        9) confirm; unsniproxy ;;
        10) echo -e "${yellow}系统即将重启...${plain}"; sleep 2; reboot ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选择${plain}"; menu ;;
    esac
}

menu
