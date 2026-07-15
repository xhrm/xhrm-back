#!/usr/bin/env bash
#===============================================================================
# Dnsmasq + SNI Proxy 完整安装脚本
# 支持系统: CentOS 7/8/9, Debian 9/10/11/12/13
#===============================================================================

set -euo pipefail
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#===============================================================================
# 颜色定义
#===============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly PLAIN='\033[0m'

#===============================================================================
# 全局变量
#===============================================================================
readonly DNSMASQ_VERSION="2.91"
readonly SNIPROXY_VERSION="0.6.0"
readonly WORK_DIR="/tmp/dnsmasq_sniproxy_install"

SYSTEM_TYPE=""
PACKAGE_MANAGER=""
SYSTEM_VERSION=""

#===============================================================================
# 日志函数
#===============================================================================
log_info() {
    echo -e "[${GREEN}Info${PLAIN}] $*"
}

log_warn() {
    echo -e "[${YELLOW}Warning${PLAIN}] $*"
}

log_error() {
    echo -e "[${RED}Error${PLAIN}] $*"
    exit 1
}

#===============================================================================
# 权限检查
#===============================================================================
check_root() {
    [[ $EUID -eq 0 ]] || log_error "请使用 root 用户执行此脚本"
}

#===============================================================================
# 系统检测
#===============================================================================
detect_system() {
    log_info "检测系统环境..."
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID}" in
            centos|rhel|rocky|almalinux)
                SYSTEM_TYPE="centos"
                SYSTEM_VERSION="${VERSION_ID%%.*}"
                PACKAGE_MANAGER=$([[ "${SYSTEM_VERSION}" == "7" ]] && echo "yum" || echo "dnf")
                ;;
            debian|ubuntu)
                SYSTEM_TYPE="debian"
                SYSTEM_VERSION="${VERSION_ID%%.*}"
                PACKAGE_MANAGER="apt"
                ;;
            *)
                log_error "不支持的系统: ${ID}"
                ;;
        esac
    else
        log_error "无法检测系统类型"
    fi
    
    log_info "系统类型: ${ID} ${VERSION_ID}, 包管理器: ${PACKAGE_MANAGER}"
}

#===============================================================================
# 禁用 SELinux (CentOS)
#===============================================================================
disable_selinux() {
    if [[ "${SYSTEM_TYPE}" == "centos" ]] && [[ -f /etc/selinux/config ]]; then
        if grep -q 'SELINUX=enforcing' /etc/selinux/config; then
            log_info "禁用 SELinux..."
            sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
            setenforce 0 || true
        fi
    fi
}

#===============================================================================
# 下载函数
#===============================================================================
download_file() {
    local filename="$1"
    local url="$2"
    local max_retries=3
    local retry=0
    
    log_info "下载 ${filename}..."
    
    while [[ $retry -lt $max_retries ]]; do
        if wget --no-check-certificate -q --show-progress -t 3 -T 60 -O "${filename}" "${url}"; then
            log_info "${filename} 下载完成"
            return 0
        fi
        
        if curl -sSL --connect-timeout 30 --max-time 300 -o "${filename}" "${url}"; then
            log_info "${filename} 下载完成 (curl)"
            return 0
        fi
        
        retry=$((retry + 1))
        [[ $retry -lt $max_retries ]] && log_warn "下载失败，第 ${retry} 次重试..." && sleep 5
    done
    
    log_error "${filename} 下载失败，请检查网络连接"
}

#===============================================================================
# 安装依赖 - CentOS
#===============================================================================
install_deps_centos() {
    log_info "安装 CentOS/RHEL 依赖包..."
    
    # EPEL 源
    if ! rpm -q epel-release &>/dev/null; then
        ${PACKAGE_MANAGER} install -y epel-release || \
        ${PACKAGE_MANAGER} install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${SYSTEM_VERSION}.noarch.rpm"
    fi
    
    # 启用 powertools (CentOS 8+)
    if [[ ${SYSTEM_VERSION} -ge 8 ]]; then
        ${PACKAGE_MANAGER} config-manager --set-enabled powertools &>/dev/null || true
    fi
    
    # 安装依赖
    ${PACKAGE_MANAGER} install -y \
        curl wget ca-certificates \
        make gcc gcc-c++ pkg-config \
        autoconf automake libtool \
        gettext gettext-devel \
        libev-devel pcre-devel nettle-devel \
        libidn-devel libnetfilter_conntrack-devel dbus-devel || \
        log_error "依赖安装失败"
    
    # 开发工具组
    ${PACKAGE_MANAGER} groupinstall -y "Development Tools" &>/dev/null || \
    ${PACKAGE_MANAGER} install -y make gcc gcc-c++ kernel-devel
    
    log_info "CentOS 依赖安装完成"
}

#===============================================================================
# 安装依赖 - Debian
#===============================================================================
install_deps_debian() {
    log_info "安装 Debian/Ubuntu 依赖包..."
    
    ${PACKAGE_MANAGER} update || {
        rm -rf /var/lib/apt/lists/*
        ${PACKAGE_MANAGER} update
    }
    
    DEBIAN_FRONTEND=noninteractive ${PACKAGE_MANAGER} install -y \
        curl wget ca-certificates \
        build-essential make gcc g++ pkg-config \
        autoconf automake libtool devscripts cdbs \
        gettext \
        libev-dev libpcre3-dev nettle-dev \
        libidn2-dev libnetfilter-conntrack-dev libdbus-1-dev || \
        log_error "依赖安装失败"
    
    log_info "Debian 依赖安装完成"
}

#===============================================================================
# 安装依赖（统一入口）
#===============================================================================
install_dependencies() {
    case "${SYSTEM_TYPE}" in
        centos) install_deps_centos ;;
        debian) install_deps_debian ;;
    esac
}

#===============================================================================
# 配置防火墙
#===============================================================================
configure_firewall() {
    local ports=("$@")
    log_info "配置防火墙，开放端口: ${ports[*]}..."
    
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        local zone=$(firewall-cmd --get-default-zone)
        for port in "${ports[@]}"; do
            firewall-cmd --permanent --zone="${zone}" --add-port="${port}/tcp" &>/dev/null
            [[ "${port}" == "53" ]] && firewall-cmd --permanent --zone="${zone}" --add-port="${port}/udp" &>/dev/null
        done
        firewall-cmd --reload &>/dev/null
    elif command -v iptables &>/dev/null; then
        for port in "${ports[@]}"; do
            iptables -L -n | grep -q "${port}" || {
                iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport "${port}" -j ACCEPT
                [[ "${port}" == "53" ]] && iptables -I INPUT -m state --state NEW -m udp -p udp --dport "${port}" -j ACCEPT
            }
        done
    fi
}

#===============================================================================
# 编译安装 Dnsmasq
#===============================================================================
install_dnsmasq() {
    log_info "========================================"
    log_info "安装 Dnsmasq ${DNSMASQ_VERSION}"
    log_info "========================================"
    
    cd "${WORK_DIR}"
    download_file "dnsmasq-${DNSMASQ_VERSION}.tar.gz" \
        "https://thekelleys.org.uk/dnsmasq/dnsmasq-${DNSMASQ_VERSION}.tar.gz"
    
    tar -zxf "dnsmasq-${DNSMASQ_VERSION}.tar.gz"
    cd "dnsmasq-${DNSMASQ_VERSION}"
    
    log_info "编译 Dnsmasq..."
    make all-i18n V=s COPTS='-DHAVE_DNSSEC -DHAVE_IDN -DHAVE_CONNTRACK -DHAVE_DBUS' -j"$(nproc)"
    make install
    
    mkdir -p /etc/dnsmasq.d
    
    # 验证
    if command -v dnsmasq &>/dev/null; then
        log_info "Dnsmasq 安装成功: $(dnsmasq --version 2>/dev/null | head -1)"
    else
        log_error "Dnsmasq 安装验证失败"
    fi
}

#===============================================================================
# 编译安装 SNI Proxy
#===============================================================================
install_sniproxy() {
    log_info "========================================"
    log_info "安装 SNI Proxy ${SNIPROXY_VERSION}"
    log_info "========================================"
    
    cd "${WORK_DIR}"
    
    # 尝试多个下载地址
    local downloaded=false
    for url in \
        "https://github.com/dlundquist/sniproxy/archive/v${SNIPROXY_VERSION}.tar.gz" \
        "https://github.com/dlundquist/sniproxy/archive/refs/tags/v${SNIPROXY_VERSION}.tar.gz" \
        "https://codeload.github.com/dlundquist/sniproxy/tar.gz/v${SNIPROXY_VERSION}"; do
        
        if download_file "sniproxy-${SNIPROXY_VERSION}.tar.gz" "${url}"; then
            downloaded=true
            break
        fi
    done
    
    [[ "${downloaded}" == "false" ]] && log_error "SNI Proxy 下载失败"
    
    tar -zxf "sniproxy-${SNIPROXY_VERSION}.tar.gz"
    cd sniproxy-*
    
    log_info "配置并编译 SNI Proxy..."
    ./configure
    make -j"$(nproc)"
    make install
    
    if command -v sniproxy &>/dev/null; then
        log_info "SNI Proxy 安装成功"
    else
        log_error "SNI Proxy 安装验证失败"
    fi
}

#===============================================================================
# 创建 systemd 服务
#===============================================================================
create_services() {
    log_info "创建 systemd 服务..."
    
    # Dnsmasq 服务
    cat > /etc/systemd/system/dnsmasq.service << 'EOF'
[Unit]
Description=Dnsmasq - DNS forwarder and DHCP server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/sbin/dnsmasq
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # SNI Proxy 服务
    cat > /etc/systemd/system/sniproxy.service << 'EOF'
[Unit]
Description=SNI Proxy - Transparent TLS proxy
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/sbin/sniproxy
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
}

#===============================================================================
# 清理临时文件
#===============================================================================
cleanup() {
    log_info "清理临时文件..."
    rm -rf "${WORK_DIR}"
}

#===============================================================================
# 显示完成信息
#===============================================================================
show_result() {
    echo ""
    echo "========================================"
    echo -e "  ${GREEN}安装完成！${PLAIN}"
    echo "========================================"
    echo ""
    echo -e "Dnsmasq:  ${GREEN}$(which dnsmasq)${PLAIN}"
    echo -e "SNI Proxy: ${GREEN}$(which sniproxy)${PLAIN}"
    echo ""
    echo -e "${YELLOW}配置文件:${PLAIN}"
    echo "  Dnsmasq:  /etc/dnsmasq.d/"
    echo "  SNI Proxy: 需自行创建配置文件"
    echo ""
    echo -e "${YELLOW}管理命令:${PLAIN}"
    echo "  systemctl start dnsmasq      # 启动 Dnsmasq"
    echo "  systemctl start sniproxy     # 启动 SNI Proxy"
    echo "  systemctl enable dnsmasq     # 开机自启"
    echo "  systemctl enable sniproxy    # 开机自启"
    echo "  systemctl status dnsmasq     # 查看状态"
    echo "  systemctl status sniproxy    # 查看状态"
    echo ""
}

#===============================================================================
# 主流程
#===============================================================================
main() {
    echo ""
    echo "========================================"
    echo "  Dnsmasq + SNI Proxy 自动安装脚本"
    echo "  支持: CentOS 7+ / Debian 9+"
    echo "========================================"
    echo ""
    
    check_root
    detect_system
    disable_selinux
    
    mkdir -p "${WORK_DIR}"
    
    install_dependencies
    install_dnsmasq
    install_sniproxy
    create_services
    configure_firewall 53 80 443 8080 8443
    cleanup
    
    show_result
}

main "$@"
