#!/bin/bash
# go一键安装脚本（c版本：语法错误完全修正版）

RED="\033[31m"      # Error message
GREEN="\033[32m"    # Success message
YELLOW="\033[33m"   # Warning message
BLUE="\033[36m"     # Info message
BOLD="\033[1m"      # 标题加粗
PLAIN='\033[0m'

# ---------- 可自定义项 ----------
ZIP_FILE="trojan-go"
CONFIG_FILE="/etc/trojan-go/config.json"
STATE_FILE="/etc/trojan-go/install-state.conf"
NGINX_CONF_PATH="/etc/nginx/conf.d/"
HTML_ZIP_URL="https://raw.githubusercontent.com/xhrm/xhrm-back/master/index.zip"
# ---------- trojan-go 下载来源（换仓库时通常只改这一段） ----------
TROJAN_ZIP_URL=""                  # ① 直接指定下载地址（最优先，无视下面所有规则）
TROJAN_ASSET_PATTERN="trojan-go-linux-{arch}.zip"   # ② 文件名模板，支持 {arch} {os} {version}
TROJAN_ARCH_ALIAS=""               # ③ 仓库对架构的写法与默认不同时填，如 x86_64 / 64bit
TROJAN_VERSION=""                  # ④ 固定 tag，如 v1.2.1（留空=自动；填了只用这一个）
TROJAN_VERSION_CHANNEL="prerelease" # ⑤ 自动选版策略：prerelease=最新 release(含预发布)优先、失败退回稳定版；stable=只跟随稳定版
TROJAN_REPO="fregie/trojan-go"     # ⑥ GitHub 仓库，换 fork 时改这里
TROJAN_BINARY_NAME="trojan-go"     # ⑦ 解压后主程序名（自动识别失败时的兜底）
TROJAN_LISTEN_ADDR=""              # ⑧ 监听地址，留空=自动（有 IPv6 用 :: 双栈，否则用 0.0.0.0）
ENABLE_BBR="auto"                  # ⑨ BBR：auto=Debian 且内核≥4.9 时自动开启；yes=强制尝试；no=不处理
BBR_CONF_FILE="/etc/sysctl.d/99-bbr.conf"   # BBR 参数落盘位置
# -------------------------------

# 运行期全局变量：先全部初始化，避免未定义变量带来意外行为
DOMAIN=""
DOMAIN_IN=""
DOMAIN_ERR=""
PASSWORD=""
PORT=""
WS="false"
WSPATH=""
PROXY_URL=""
REMOTE_HOST=""
ALLOW_SPIDER="n"
CERT_FILE=""
KEY_FILE=""
VERSION=""
DOWNLOAD_URL=""
CANDIDATES=()
TAGS=()

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

randStr() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-16}"
}

validDomain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

normalizeDomain() {
    local raw="$1" bad
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw%.}"
    DOMAIN_IN="${raw,,}"
    DOMAIN_ERR=""

    if [[ -z "$DOMAIN_IN" ]]; then
        DOMAIN_ERR="域名不能为空"
        return 1
    fi
    if [[ "$DOMAIN_IN" =~ [[:space:]] ]]; then
        DOMAIN_ERR="域名里不能有空格，请只输入域名本身"
        return 1
    fi
    if [[ "$DOMAIN_IN" == http://* || "$DOMAIN_IN" == https://* ]]; then
        DOMAIN_ERR="只填域名本身，不要带 http:// 或 https:// 前缀"
        return 1
    fi
    if [[ "$DOMAIN_IN" =~ [^a-z0-9.-] ]]; then
        bad=$(printf '%s' "$DOMAIN_IN" | tr -d 'a-z0-9.-')
        DOMAIN_ERR="含有不允许的标点或字符「${bad}」，域名只能由字母、数字、连字符(-)和点(.)组成"
        return 1
    fi
    if ! validDomain "$DOMAIN_IN"; then
        DOMAIN_ERR="域名格式不正确，应为类似 example.com 的形式"
        return 1
    fi
    return 0
}

checkSystem() {
    result=$(id | awk '{print $1}')
    if [[ $result != "uid=0(root)" ]]; then
        echo -e " ${RED}请以root身份执行该脚本${PLAIN}"
        exit 1
    fi

    if ! command -v apt >/dev/null 2>&1; then
        echo -e " ${RED}不受支持的Linux系统（需要 Debian/Ubuntu 等 apt 系统）${PLAIN}"
        exit 1
    fi
    PMT="apt"
    CMD_INSTALL="apt install -y "
    export DEBIAN_FRONTEND=noninteractive

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e " ${RED}系统版本过低，请升级到最新版本${PLAIN}"
        exit 1
    fi
}

saveState() {
    mkdir -p /etc/trojan-go
    cat > "$STATE_FILE" <<-EOF
DOMAIN='${DOMAIN}'
PASSWORD='${PASSWORD}'
PORT='${PORT}'
WS='${WS}'
WSPATH='${WSPATH}'
PROXY_URL='${PROXY_URL}'
ALLOW_SPIDER='${ALLOW_SPIDER}'
CERT_FILE='${CERT_FILE}'
KEY_FILE='${KEY_FILE}'
VERSION='${VERSION}'
EOF
    chmod 600 "$STATE_FILE"
}

confGet() {
    grep -m1 "\"$1\"[[:space:]]*:" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f4
}

loadStateFallback() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    DOMAIN="$(confGet sni)"
    [[ -z "$DOMAIN" ]] && DOMAIN="$(confGet host)"
    PASSWORD="$(sed -n '/"password"/{n;p;q;}' "$CONFIG_FILE" | sed 's/[" ,]//g')"
    PORT="$(grep -m1 'local_port' "$CONFIG_FILE" | cut -d: -f2 | tr -d "\",' '")"
    WS="$(sed -n '/"websocket"/{n;p;q;}' "$CONFIG_FILE" | cut -d: -f2 | tr -d "\",' '")"
    WSPATH="$(confGet path)"
    CERT_FILE="$(confGet cert)"
    KEY_FILE="$(confGet key)"
    [[ -n "$DOMAIN" ]] || return 1
    return 0
}

loadState() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        [[ -n "$DOMAIN" ]] && return 0
    fi
    loadStateFallback
}

listenAddr() {
    if [[ -n "$TROJAN_LISTEN_ADDR" ]]; then
        echo "$TROJAN_LISTEN_ADDR"
    elif ip -6 addr show 2>/dev/null | grep -q 'inet6'; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

bbrEnabled() {
    [[ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" = "bbr" ]]
}

bbrText() {
    local cc qdisc
    cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
    if [[ "$cc" = "bbr" ]]; then
        echo "${GREEN}已开启${PLAIN}（拥塞控制 bbr，队列 ${qdisc:-未知}）"
    else
        echo "${RED}未开启${PLAIN}（当前拥塞控制 ${cc:-未知}）"
    fi
}

setBBR() {
    if [[ "$ENABLE_BBR" = "no" ]]; then
        colorEcho $YELLOW " 已按配置跳过 BBR（ENABLE_BBR=\"no\"）"
        return 0
    fi
    if [[ "$ENABLE_BBR" = "auto" && ! -f /etc/debian_version ]]; then
        colorEcho $YELLOW " 非 Debian 系统，跳过 BBR 设置"
        return 0
    fi

    local kver k1 k2
    kver=$(uname -r)
    k1=${kver%%.*}
    k2=$(echo "${kver#*.}" | cut -d. -f1)
    if [[ ! "$k1" =~ ^[0-9]+$ || ! "$k2" =~ ^[0-9]+$ ]]; then
        colorEcho $YELLOW " 无法识别内核版本（${kver}），跳过 BBR 设置"
        return 0
    fi
    if (( k1 < 4 || (k1 == 4 && 10#$k2 < 9) )); then
        colorEcho $YELLOW " 内核 ${kver} 不支持 BBR（需要 4.9 以上），跳过"
        return 0
    fi

    mkdir -p /etc/sysctl.d
    cat > "$BBR_CONF_FILE" <<-EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -p "$BBR_CONF_FILE" >/dev/null 2>&1 && bbrEnabled; then
        colorEcho $BLUE " BBR 已开启（拥塞控制 bbr / 队列 fq）"
    else
        colorEcho $YELLOW " BBR 未能立即生效，重启后会自动重试"
    fi
    return 0
}

portOwner() {
    ss -ntlp 2>/dev/null | awk -v p=":${1}$" 'NR>1 && $4 ~ p'
}

status() {
    if [[ "$(command -v trojan-go)" = "" ]]; then
        echo 0
        return
    fi
    if [[ ! -f $CONFIG_FILE ]]; then
        echo 1
        return
    fi
    if systemctl is-active --quiet trojan-go; then
        echo 3
    else
        echo 2
    fi
}

statusText() {
    res=`status`
    case $res in
        1) echo -e ${GREEN}已安装${PLAIN} ${RED}缺少配置文件${PLAIN} ;;
        2) echo -e ${GREEN}已安装${PLAIN} ${RED}未运行${PLAIN} ;;
        3) echo -e ${GREEN}已安装${PLAIN} ${GREEN}正在运行${PLAIN} ;;
        *) echo -e ${RED}未安装${PLAIN} ;;
    esac
}

pkgArch() {
    if [[ -n "$TROJAN_ARCH_ALIAS" ]]; then
        echo "$TROJAN_ARCH_ALIAS"
    else
        archAffix
    fi
}

platformArchRegex() {
    case "$(uname -m)" in
        i686|i386)          echo 'i386|i686|386' ;;
        x86_64|amd64)       echo 'amd64|x86_64|x64' ;;
        *armv8*|aarch64)    echo 'arm64|aarch64|armv8' ;;
        *armv7*|armv6l)     echo 'armv7|armhf' ;;
        *armv6*)            echo 'armv6|armel' ;;
        *mips64le*)         echo 'mips64le' ;;
        *mips64*)           echo 'mips64' ;;
        *mipsle*)           echo 'mipsle|mipsel' ;;
        *mips*)             echo 'mips' ;;
        *)                  return 1 ;;
    esac
}

apiLatestTag() {
    curl -fsSL --max-time 15 "https://api.github.com/repos/${TROJAN_REPO}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4
}

apiNewestTag() {
    curl -fsSL --max-time 20 "https://api.github.com/repos/${TROJAN_REPO}/releases?per_page=10" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4
}

resolveTags() {
    TAGS=()
    VERSION=""

    if [[ -n "$TROJAN_VERSION" ]]; then
        TAGS+=("$TROJAN_VERSION")
        VERSION="$TROJAN_VERSION"
        return 0
    fi

    local tag stable
    if [[ "$TROJAN_VERSION_CHANNEL" != "stable" ]]; then
        tag=$(apiNewestTag)
        [[ -n "$tag" ]] && TAGS+=("$tag")
    fi

    stable=$(apiLatestTag)
    [[ -n "$stable" && "$stable" != "${TAGS[0]:-}" ]] && TAGS+=("$stable")
    [[ -n "${TAGS[0]:-}" ]] && VERSION="${TAGS[0]}"
    return 0
}

tagFromUrl() {
    local u="$1"
    [[ "$u" == */releases/download/* ]] || return 0
    u="${u#*/releases/download/}"
    echo "${u%%/*}"
}

apiAssetList() {
    local api="${1:-https://api.github.com/repos/${TROJAN_REPO}/releases/latest}"
    curl -fsSL --max-time 20 "$api" 2>/dev/null \
        | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4
}

buildDownloadCandidates() {
    CANDIDATES=()
    [[ -n "$TROJAN_ZIP_URL" ]] && CANDIDATES+=("$TROJAN_ZIP_URL")
    if [[ -z "$TROJAN_ASSET_PATTERN" ]]; then
        resolveTags
        return 0
    fi

    local arch name tag
    arch=$(pkgArch) || { exit 1; }
    resolveTags
    for tag in "${TAGS[@]}"; do
        name="${TROJAN_ASSET_PATTERN//\{arch\}/$arch}"
        name="${name//\{os\}/linux}"
        name="${name//\{version\}/$tag}"
        CANDIDATES+=("https://github.com/${TROJAN_REPO}/releases/download/${tag}/${name}")
    done
    return 0
}

archAffix() {
    case "${1:-"$(uname -m)"}" in
        i686|i386) echo '386' ;;
        x86_64|amd64) echo 'amd64' ;;
        *armv7*|armv6l) echo 'armv7' ;;
        *armv8*|aarch64) echo 'armv8' ;;
        *armv6*) echo 'armv6' ;;
        *arm*) echo 'arm' ;;
        *mips64le*) echo 'mips64le' ;;
        *mips64*) echo 'mips64' ;;
        *mipsle*) echo 'mipsle-softfloat' ;;
        *mips*) echo 'mips-softfloat' ;;
        *) return 1 ;;
    esac
    return 0
}

getData() {
    echo ""
    local can_change=$1
    if [[ "$can_change" != "yes" ]]; then
        while true; do
            read -p " 请输入伪装域名：" domain_input
            if normalizeDomain "$domain_input"; then
                DOMAIN="$DOMAIN_IN"
                break
            fi
            echo -e " ${RED}${DOMAIN_ERR}${PLAIN}"
        done
        PASSWORD=$(randStr 16)
    else
        loadState || exit 1
    fi

    while true; do
        read -p " 请输入go端口[1-65535，默认${PORT:-443}]：" new_port
        [[ -z "$new_port" ]] && break
        if [[ "$new_port" =~ ^[0-9]+$ ]] && (( 10#$new_port >= 1 && 10#$new_port <= 65535 )); then
            PORT="$((10#$new_port))"
            break
        fi
        echo -e "${RED}端口必须是 1-65535 之间的数字${PLAIN}"
    done
    [[ -z "$PORT" ]] && PORT=443

    if [[ "$WS" = "true" ]]; then
        while true; do
            read -p " 请输入伪装路径，以/开头(回车随机)：" wspath_input
            if [[ -z "${wspath_input}" ]]; then
                WSPATH="/$(randStr 8)"
                break
            elif [[ "${wspath_input:0:1}" != "/" ]]; then
                echo " 伪装路径必须以/开头！"
            else
                WSPATH="${wspath_input}"
                break
            fi
        done
    fi

    read -p " 请选择伪装站类型 [1: 静态网站, 2: 反代，默认1]：" answer
    answer=${answer:-1}
    [[ "$answer" = "2" ]] && read -p " 请输入反代站点(以http或https开头)：" PROXY_URL
}

installNginx() {
    $CMD_INSTALL nginx
    systemctl enable nginx
}

startNginx() { systemctl start nginx; }
stopNginx() { systemctl stop nginx; }

getCert() {
    mkdir -p /etc/trojan-go
    $CMD_INSTALL socat openssl cron
    systemctl start cron
    systemctl enable cron

    [[ -f ~/.acme.sh/acme.sh ]] || curl -fsSL https://get.acme.sh | sh -s email=bangs@${DOMAIN}
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --keylength ec-256 --standalone
    CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
    KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE"
}

writeRobots() {
    mkdir -p /usr/share/nginx/html
    [[ "$ALLOW_SPIDER" = "n" ]] && printf 'User-Agent: *\nDisallow: /\n' > /usr/share/nginx/html/robots.txt
}

configNginx() {
    mkdir -p /usr/share/nginx/html "$NGINX_CONF_PATH"
    cat > "${NGINX_CONF_PATH}${DOMAIN}.conf"<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;
}
EOF
    writeRobots
    nginx -t
}

downloadTrojanPackage() {
    rm -f /tmp/${ZIP_FILE}.pkg
    buildDownloadCandidates
    for url in "${CANDIDATES[@]}"; do
        [[ -n "$url" ]] || continue
        if wget -q -O /tmp/${ZIP_FILE}.pkg "$url" && [[ -s /tmp/${ZIP_FILE}.pkg ]]; then
            DOWNLOAD_URL="$url"
            return 0
        fi
    done
    exit 1
}

downloadFile() {
    downloadTrojanPackage
    wget -q -O /tmp/html.zip "$HTML_ZIP_URL" || true
}

installTrojan() {
    mkdir -p "/tmp/${ZIP_FILE}"
    unzip -q -o "/tmp/${ZIP_FILE}.pkg" -nodir "/tmp/${ZIP_FILE}" 2>/dev/null || unzip -q -o "/tmp/${ZIP_FILE}.pkg" -d "/tmp/${ZIP_FILE}"
    local bin
    bin=$(find "/tmp/${ZIP_FILE}" -type f -name "${TROJAN_BINARY_NAME}" | head -n1)
    [[ -z "$bin" ]] && bin=$(find "/tmp/${ZIP_FILE}" -type f -size +1M ! -name '*.dat' | head -n1)
    cp -f "$bin" /usr/bin/trojan-go
    chmod 755 /usr/bin/trojan-go

    cat > /etc/systemd/system/trojan-go.service <<-EOF
[Unit]
Description=trojan-go
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/trojan-go -config /etc/trojan-go/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable trojan-go
}

configTrojan() {
    mkdir -p /etc/trojan-go
    cat > "$CONFIG_FILE" <<-EOF
{
  "run_type": "server",
  "local_addr": "$(listenAddr)",
  "local_port": ${PORT},
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["$PASSWORD"],
  "ssl": {
    "cert": "${CERT_FILE}",
    "key": "${KEY_FILE}"
  },
  "websocket": {
    "enabled": ${WS},
    "path": "${WSPATH}",
    "host": "${DOMAIN}"
  }
}
EOF
    chmod 600 "$CONFIG_FILE"
}

addIptablesRules() {
    modprobe ip_tables 2>/dev/null || true
    modprobe iptable_filter 2>/dev/null || true

    for p in 80 443 "$PORT"; do
        iptables -w -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -w -I INPUT -p tcp --dport "$p" -j ACCEPT
    done

    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive "${APT_INSTALL_CMD[@]}" iptables-persistent >/dev/null 2>&1 || true
    fi
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

setFirewall() {
    addIptablesRules
}

install() {
    getData
    $PMT update
    $CMD_INSTALL wget curl unzip tar openssl ca-certificates kmod xz-utils cron
    setBBR
    installNginx
    setFirewall
    getCert
    configNginx
    downloadFile
    installTrojan
    configTrojan
    saveState
    start
}

start() {
    systemctl daemon-reload
    sleep 1
    stopNginx
    startNginx
    systemctl restart trojan-go
}

stop() {
    stopNginx
    systemctl stop trojan-go
}

restart() {
    stop
    start
}

showInfo() {
    loadState
    statusText
    echo "域名: $DOMAIN"
    echo "端口: $PORT"
    echo "密码: $PASSWORD"
}

menu() {
    echo "1. 安装"
    echo "2. 重启"
    echo "3. 状态"
    read -p "请选择: " choice
    case $choice in
        1) install ;;
        2) restart ;;
        3) showInfo ;;
        *) exit 0 ;;
    esac
}

checkSystem
action="${1:-menu}"
case "$action" in
    menu|start|restart|stop|showInfo|reconfig) ${action} ;;
    *) menu ;;
esac
