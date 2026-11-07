#!/bin/bash
# go一键安装脚本（优化修复版：解决 Debian 偶发需重启及 iptables 持久化问题）


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
PACKAGE_FILE="/tmp/${ZIP_FILE}.pkg"
PACKAGE_DIR="/tmp/${ZIP_FILE}"
HTML_ZIP_FILE="/tmp/html.zip"
APT_CMD=(apt)
APT_INSTALL_CMD=(apt install -y)
# ---------- trojan-go 下载来源（换仓库时通常只改这一段） ----------
TROJAN_ZIP_URL=""                  # ① 直接指定下载地址
TROJAN_ASSET_PATTERN="trojan-go-linux-{arch}.zip"   # ② 文件名模板
TROJAN_ARCH_ALIAS=""               # ③ 架构别名
TROJAN_VERSION=""                  # ④ 固定 tag
TROJAN_VERSION_CHANNEL="prerelease" # ⑤ 自动选版策略
TROJAN_REPO="fregie/trojan-go"     # ⑥ GitHub 仓库
TROJAN_BINARY_NAME="trojan-go"     # ⑦ 解压后主程序名
TROJAN_LISTEN_ADDR=""              # ⑧ 监听地址
ENABLE_BBR="auto"                  # ⑨ BBR 策略
BBR_CONF_FILE="/etc/sysctl.d/99-bbr.conf"   # BBR 参数落盘位置
# -------------------------------

# 运行期全局变量
DOMAIN=""
DOMAINS=()
DOMAIN_IN=""
DOMAIN_ERR=""
ORIGINAL_DOMAIN=""
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

normalizeDomains() {
    local input="$1" token existing raw_index=0
    local -a raw_domains=()
    local -a normalized_domains=()

    read -r -a raw_domains <<< "$input"
    if [[ ${#raw_domains[@]} -eq 0 ]]; then
        DOMAIN_ERR="至少填写一个域名"
        return 1
    fi

    for token in "${raw_domains[@]}"; do
        ((raw_index+=1))
        if ! normalizeDomain "$token"; then
            if [[ ${#raw_domains[@]} -gt 1 ]]; then
                DOMAIN_ERR="第 ${raw_index} 个域名无效：${DOMAIN_ERR}"
            fi
            DOMAINS=()
            return 1
        fi

        for existing in "${normalized_domains[@]}"; do
            [[ "$existing" = "$DOMAIN_IN" ]] && continue 2
        done
        normalized_domains+=("$DOMAIN_IN")
    done

    DOMAINS=("${normalized_domains[@]}")
    DOMAIN="${DOMAINS[0]}"
    DOMAIN_IN="$DOMAIN"
    DOMAIN_ERR=""
    return 0
}

domainsText() {
    local domain first="true"
    if [[ ${#DOMAINS[@]} -gt 0 ]]; then
        for domain in "${DOMAINS[@]}"; do
            if [[ "$first" = "true" ]]; then
                printf '%s' "$domain"
                first="false"
            else
                printf ' %s' "$domain"
            fi
        done
        printf '\n'
    else
        printf '%s\n' "$DOMAIN"
    fi
}

ensureDomains() {
    if [[ ${#DOMAINS[@]} -eq 0 && -n "$DOMAIN" ]]; then
        DOMAINS=("$DOMAIN")
    elif [[ ${#DOMAINS[@]} -gt 0 ]]; then
        DOMAIN="${DOMAINS[0]}"
    fi
}

checkSystem() {
    if (( EUID != 0 )); then
        echo -e " ${RED}请以root身份执行该脚本${PLAIN}"
        exit 1
    }

    if ! command -v apt >/dev/null 2>&1; then
        echo -e " ${RED}不受支持的Linux系统（需要 Debian/Ubuntu 等 apt 系统）${PLAIN}"
        exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e " ${RED}系统版本过低，请升级到最新版本${PLAIN}"
        exit 1
    fi
}

saveState() {
    local state_tmp domain
    ensureDomains
    mkdir -p "$(dirname "$STATE_FILE")"
    state_tmp=$(mktemp "${STATE_FILE}.XXXXXX") || {
        colorEcho $RED " 无法创建安装状态临时文件"
        return 1
    }

    if ! {
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'DOMAINS=('
        for domain in "${DOMAINS[@]}"; do
            printf '%q ' "$domain"
        done
        printf ')\n'
        printf 'PASSWORD=%q\n' "$PASSWORD"
        printf 'PORT=%q\n' "$PORT"
        printf 'WS=%q\n' "$WS"
        printf 'WSPATH=%q\n' "$WSPATH"
        printf 'PROXY_URL=%q\n' "$PROXY_URL"
        printf 'ALLOW_SPIDER=%q\n' "$ALLOW_SPIDER"
        printf 'CERT_FILE=%q\n' "$CERT_FILE"
        printf 'KEY_FILE=%q\n' "$KEY_FILE"
        printf 'VERSION=%q\n' "$VERSION"
    } > "$state_tmp"; then
        rm -f "$state_tmp"
        colorEcho $RED " 安装状态写入失败"
        return 1
    fi

    if ! mv -f "$state_tmp" "$STATE_FILE"; then
        rm -f "$state_tmp"
        colorEcho $RED " 安装状态替换失败"
        return 1
    fi
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
    DOMAINS=("$DOMAIN")
    return 0
}

loadState() {
    if [[ -f "$STATE_FILE" ]]; then
        DOMAINS=()
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        ensureDomains
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
    k2=${kver#*.}
    k2=${k2%%.*}
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
# 由 go 一键脚本写入：开启 BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -p "$BBR_CONF_FILE" >/dev/null 2>&1 && bbrEnabled; then
        colorEcho $BLUE " BBR 已开启（拥塞控制 bbr / 队列 fq），配置已写入 ${BBR_CONF_FILE}"
    else
        colorEcho $YELLOW " BBR 未能立即生效（当前内核可能没提供 bbr/fq）"
        colorEcho $YELLOW " 配置已写入 ${BBR_CONF_FILE}，重启后会自动重试"
        colorEcho $YELLOW " 当前拥塞控制：$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    fi
    return 0
}

portOwner() {
    ss -ntlp 2>/dev/null | awk -v p=":${1}$" 'NR>1 && $4 ~ p'
}

status() {
    if ! command -v trojan-go >/dev/null 2>&1; then
        echo 0
        return
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
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
    local current_status="${1:-$(status)}"
    case $current_status in
        1)
            echo -e ${GREEN}已安装${PLAIN} ${RED}缺少配置文件${PLAIN}
            ;;
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
        if [[ -n "$tag" ]]; then
            TAGS+=("$tag")
        else
            colorEcho $YELLOW " 查询最新 release（含预发布）失败，改用稳定版" >&2
        fi
    fi

    stable=$(apiLatestTag)
    if [[ -n "$stable" && "$stable" != "${TAGS[0]:-}" ]]; then
        TAGS+=("$stable")
    fi
    [[ -n "${TAGS[0]:-}" ]] && VERSION="${TAGS[0]}"

    if [[ ${#TAGS[@]} -gt 1 ]]; then
        colorEcho $BLUE " 版本候选（按优先级）：${TAGS[*]}"
    elif [[ ${#TAGS[@]} -eq 1 ]]; then
        colorEcho $BLUE " 版本：${TAGS[0]}"
    fi
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
    arch=$(pkgArch) || {
        colorEcho $RED " 暂不支持的系统架构：$(uname -m)"
        colorEcho $YELLOW " 可在脚本顶部设置 TROJAN_ARCH_ALIAS（仓库的架构写法）或 TROJAN_ZIP_URL"
        exit 1
    }

    resolveTags
    if [[ ${#TAGS[@]} -eq 0 ]]; then
        if [[ "$TROJAN_ASSET_PATTERN" == *"{version}"* ]]; then
            colorEcho $YELLOW " 文件名模板含 {version}，但没取到 release tag，改为自动识别资源列表"
            return 0
        fi
        name="${TROJAN_ASSET_PATTERN//\{arch\}/$arch}"
        name="${name//\{os\}/linux}"
        CANDIDATES+=("https://github.com/${TROJAN_REPO}/releases/latest/download/${name}")
        colorEcho $YELLOW " 未能查询 release 列表，改用稳定版永久链接（具体版本由 GitHub 决定）"
        return 0
    fi

    for tag in "${TAGS[@]}"; do
        name="${TROJAN_ASSET_PATTERN//\{arch\}/$arch}"
        name="${name//\{os\}/linux}"
        name="${name//\{version\}/$tag}"
        CANDIDATES+=("https://github.com/${TROJAN_REPO}/releases/download/${tag}/${name}")
    done
    return 0
}

printDownloadHelp() {
    colorEcho $YELLOW " 可以这样指定下载来源（改脚本顶部即可）："
    echo "   1) TROJAN_ASSET_PATTERN=\"仓库的真实文件名模板\"，如 trojan-go-linux-{arch}.tar.gz"
    echo "      不同仓库架构写法不同，可配合 TROJAN_ARCH_ALIAS=\"x86_64\" 这类覆盖"
    echo "   2) 或直接把地址写进 TROJAN_ZIP_URL=\"https://.../xxx.zip\""
    echo "   3) 或改 TROJAN_REPO / TROJAN_VERSION 指向实际仓库与版本"
    echo "   4) 版本策略：TROJAN_VERSION=\"v1.2.1\" 固定版本；TROJAN_VERSION_CHANNEL=stable 只跟随稳定版"
    if [[ ${#TAGS[@]} -gt 0 ]]; then
        echo "   本次尝试的版本：${TAGS[*]}（按优先级）"
    else
        echo "   本次尝试的版本：未取到 release tag，已回退 releases/latest 永久链接"
    fi
    echo "   当前架构：$(uname -m)   模板中的架构取值：$(pkgArch 2>/dev/null)"
}

archAffix() {
    case "${1:-"$(uname -m)"}" in
        i686|i386)          echo '386' ;;
        x86_64|amd64)       echo 'amd64' ;;
        *armv7*|armv6l)     echo 'armv7' ;;
        *armv8*|aarch64)    echo 'armv8' ;;
        *armv6*)            echo 'armv6' ;;
        *arm*)              echo 'arm' ;;
        *mips64le*)         echo 'mips64le' ;;
        *mips64*)           echo 'mips64' ;;
        *mipsle*)           echo 'mipsle-softfloat' ;;
        *mips*)             echo 'mips-softfloat' ;;
        *)                  return 1 ;;
    esac
    return 0
}

promptDomains() {
    local domain_input
    echo " 提示：多个域名请用空格分隔；第一个域名作为主域名。"
    while true; do
        read -r -p " 请输入伪装域名（多个用空格分隔）：" domain_input
        if normalizeDomains "$domain_input"; then
            return 0
        fi
        echo -e " ${RED}${DOMAIN_ERR}${PLAIN}"
    done
}

getData() {
    local can_change="${1:-}"
    local answer new_port wspath_input len proxy_input default_site
    echo ""
    if [[ "$can_change" != "yes" ]]; then
        promptDomains
        colorEcho $BLUE " 伪装域名(host)：$(domainsText)"
        if [[ ${#DOMAINS[@]} -gt 1 ]]; then
            colorEcho $BLUE " 域名模式：多域名（${#DOMAINS[@]} 个，${DOMAIN} 为主域名）"
        else
            colorEcho $BLUE " 域名模式：单域名"
        fi

        PASSWORD=$(randStr 16)
    else
        if ! loadState || [[ -z "$DOMAIN" ]]; then
            colorEcho $RED " 读取已有配置失败，请重新安装。"
            exit 1
        fi
        ORIGINAL_DOMAIN="$DOMAIN"
        colorEcho $BLUE " 当前伪装域名(host)：$(domainsText)"
        if [[ ${#DOMAINS[@]} -gt 1 ]]; then
            colorEcho $BLUE " 当前域名模式：多域名（${#DOMAINS[@]} 个，${DOMAIN} 为主域名）"
        else
            colorEcho $BLUE " 当前域名模式：单域名"
        fi
        read -r -p " 是否修改伪装域名列表？[y/n]" answer
        if [[ "${answer,,}" = "y" ]]; then
            promptDomains
            if [[ "$DOMAIN" != "$ORIGINAL_DOMAIN" ]]; then
                CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
                KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
            fi
            colorEcho $BLUE " 新的伪装域名(host)：$(domainsText)"
        fi
        colorEcho $BLUE " 当前 go端口：$PORT"
        colorEcho $BLUE " 当前 websocket：$WS"
        echo ""
        if [[ "$WS" = "true" ]]; then
            read -p " 是否关闭websocket（改回443直连）？[y/n]" answer
            [[ "${answer,,}" = "y" ]] && WS="false"
        else
            read -p " 是否转换成WS版本？[y/n]" answer
            [[ "${answer,,}" = "y" ]] && WS="true"
        fi
    fi

    echo ""
    while true
    do
        read -p " 请输入go端口[1-65535的一个数字，默认${PORT:-443}]：" new_port
        [[ -z "$new_port" ]] && break
        if [[ "$new_port" =~ ^[0-9]+$ ]] && (( 10#$new_port >= 1 && 10#$new_port <= 65535 )); then
            PORT="$((10#$new_port))"
            break
        fi
        echo -e "${RED}端口必须是 1-65535 之间的数字${PLAIN}"
    done
    [[ -z "$PORT" ]] && PORT=443
    colorEcho $BLUE " go端口：$PORT"
    colorEcho $BLUE " go密码：$PASSWORD"

    if [[ "$WS" = "true" ]]; then
        echo ""
        while true
        do
            read -p " 请输入伪装路径，以/开头(不懂请直接回车)${WSPATH:+[默认：$WSPATH]}：" wspath_input
            if [[ -z "${wspath_input}" ]]; then
                if [[ -z "$WSPATH" ]]; then
                    len=$(shuf -i 5-12 -n 1)
                    WSPATH="/$(randStr "$len")"
                fi
                break
            elif [[ "${wspath_input:0:1}" != "/" ]]; then
                echo " 伪装路径必须以/开头！"
            elif [[ "${wspath_input}" = "/" ]]; then
                echo  " 不能使用根路径！"
            else
                WSPATH="${wspath_input}"
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
    if [[ -n "$PROXY_URL" ]]; then
        default_site=2
        read -p "  请选择伪装网站类型[默认：2，当前反代 ${PROXY_URL}]：" answer
    else
        default_site=1
        read -p "  请选择伪装网站类型[默认：1]" answer
    fi
    answer=${answer:-$default_site}

    case $answer in
    1)
        PROXY_URL=""
        ;;
    2)
        read -p " 请输入反代站点(以http或者https开头)${PROXY_URL:+[默认：$PROXY_URL]}：" proxy_input
        [[ -n "$proxy_input" ]] && PROXY_URL="$proxy_input"
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

    REMOTE_HOST=$(echo "$PROXY_URL" | cut -d/ -f3)
    echo ""
    colorEcho $BLUE " 伪装网站：$PROXY_URL"


    echo ""
    colorEcho $BLUE " 是否允许搜索引擎爬取网站？[当前：$ALLOW_SPIDER]"
    echo "    y)允许，会有更多ip请求网站，但会消耗一些流量，vps流量充足情况下推荐使用"
    echo "    n)不允许，爬虫不会访问网站，访问ip比较单一，但能节省vps流量"
    read -p "  请选择：[y/n] " answer
    if [[ "${answer,,}" = "y" ]]; then
        ALLOW_SPIDER="y"
    elif [[ "${answer,,}" = "n" ]]; then
        ALLOW_SPIDER="n"
    elif [[ "$can_change" != "yes" ]]; then
        ALLOW_SPIDER="n"
    fi
    echo ""

    colorEcho $BLUE " 允许搜索引擎：$ALLOW_SPIDER"
}

DEFAULT_RESTART_TIME="00:10"
SERVICE_NAME="trojan-go"
LOG_FILE="/etc/trojan-go/log.txt"
CRON_MARKER="auto_restart_$SERVICE_NAME"
CRON_FILE="/etc/cron.d/trojan-go-autorestart"
CURRENT_RESTART_TIME=""
AUTO_RESTART_STATUS="disabled"

getAutoRestartStatus() {
    AUTO_RESTART_STATUS="disabled"
    CURRENT_RESTART_TIME=""
    if [[ -f "$CRON_FILE" ]] && grep -q "$CRON_MARKER" "$CRON_FILE"; then
        local line minute hour
        line=$(grep "$CRON_MARKER" "$CRON_FILE")
        read -r minute hour _ <<< "$line"
        printf -v CURRENT_RESTART_TIME "%02d:%02d" "$hour" "$minute"
        AUTO_RESTART_STATUS="enabled"
    fi
    echo "$AUTO_RESTART_STATUS"
}

setAutoRestart() {
    local time_str="${1:-$DEFAULT_RESTART_TIME}"
    local hour minute
    hour=${time_str%%:*}
    minute=${time_str#*:}
    minute=${minute%%:*}
    
    hour=${hour#0}
    minute=${minute#0}
    [[ -z "$hour" ]] && hour=0
    [[ -z "$minute" ]] && minute=10

    CRON_SERVICE="cron"
    if ! systemctl list-unit-files | grep -qE '^cron\.service'; then
        echo "未找到 cron 服务，请确认已安装 cron。"
        return 1
    fi

    if ! systemctl is-active --quiet "$CRON_SERVICE"; then
        echo "正在启动 $CRON_SERVICE 服务..."
        systemctl start "$CRON_SERVICE"
        systemctl enable "$CRON_SERVICE" >/dev/null 2>&1 || true
    fi

    echo "$minute $hour * * * root rm -f $LOG_FILE; /bin/systemctl restart $SERVICE_NAME # $CRON_MARKER" > $CRON_FILE
    chmod 644 $CRON_FILE

    echo -e " ${BLUE}定时任务已设置：每天 $(printf '%02d:%02d' "$hour" "$minute") 清理日志并自动重启 $SERVICE_NAME${PLAIN}"
}

disableAutoRestart() {
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        echo -e " ${BLUE}服务定时重启已关闭${PLAIN}"
    else
        echo -e " ${YELLOW}服务定时重启未启用${PLAIN}"
    fi
}

modifyAutoRestartTime() {
    read -p "请输入新的服务重启时间 (格式 HH:MM，例如 00:10)：" NEW_TIME
    if [[ -z "$NEW_TIME" ]]; then
        echo "未输入新时间，取消修改"
        return
    fi
    if [[ ! $NEW_TIME =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "错误：时间格式无效，请使用 HH:MM"
        return 1
    fi
    
    disableAutoRestart
    setAutoRestart "$NEW_TIME"
}

installNginx() {
    echo ""
    colorEcho $BLUE " 安装nginx..."
    if ! "${APT_INSTALL_CMD[@]}" nginx; then
        colorEcho $RED " Nginx安装失败"
        exit 1
    fi
    systemctl enable nginx
}

startNginx() {
    systemctl start nginx
}

stopNginx() {
    systemctl stop nginx
}

certKeyMatch() {
    local cert=$1 key=$2 pub_cert pub_key
    [[ -f "$cert" && -f "$key" ]] || return 1
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    pub_cert=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum)
    pub_key=$(openssl pkey -in "$key" -pubout -outform der -passin pass: 2>/dev/null | sha256sum)
    [[ -n "$pub_cert" && "$pub_cert" = "$pub_key" ]]
}

certCoversDomain() {
    local cert=$1 domain=$2 all n suffix names cn
    cn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -o 'CN[[:space:]]*=[[:space:]]*[^,/]*' | head -n1 | sed 's/.*=[[:space:]]*//')
    names=$(openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -o 'DNS:[^,]*' | sed 's/DNS://')
    all=$(printf '%s\n%s\n' "$names" "$cn")
    while read -r n; do
        n=$(echo "$n" | tr -d ' ')
        [[ -n "$n" ]] || continue
        [[ "$n" = "$domain" ]] && return 0
        if [[ "$n" == "*."* ]]; then
            suffix="${n#\*.}"
            [[ "$domain" == *.$suffix ]] && return 0
        fi
    done <<< "$all"
    return 1
}

certCoversDomains() {
    local cert=$1 domain
    ensureDomains
    for domain in "${DOMAINS[@]}"; do
        certCoversDomain "$cert" "$domain" || return 1
    done
    return 0
}

findLocalCert() {
    local p k keys
    for p in /root/*.pem; do
        [[ -f "$p" ]] || continue
        k="${p%.pem}.key"
        if [[ ! -f "$k" ]]; then
            keys=(/root/*.key)
            if [[ ${#keys[@]} -eq 1 && -f "${keys[0]}" ]]; then
                k="${keys[0]}"
            else
                continue
            fi
        fi
        if certKeyMatch "$p" "$k"; then
            if certCoversDomains "$p"; then
                LOCAL_CERT="$p"
                LOCAL_KEY="$k"
                return 0
            fi
            colorEcho $YELLOW " 跳过未覆盖全部域名的证书对：$p / $k"
            continue
        fi
        colorEcho $YELLOW " 跳过不可用的证书对：$p / $k"
    done
    return 1
}

getCert() {
    local res domain
    local -a domain_args=()
    mkdir -p /etc/trojan-go

    if findLocalCert; then
        echo -e "${GREEN} 检测到本地证书：${LOCAL_CERT}${PLAIN}"
        echo -e "${GREEN} 对应私钥：${LOCAL_KEY}${PLAIN}"
        openssl x509 -in "$LOCAL_CERT" -noout -subject 2>/dev/null | sed 's/^subject=/ 证书主体：/'
        CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
        KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
        cp -f "$LOCAL_CERT" "$CERT_FILE"
        cp -f "$LOCAL_KEY" "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        chmod 600 "$KEY_FILE"
        return 0
    fi

    if certKeyMatch "$CERT_FILE" "$KEY_FILE"; then
        if certCoversDomains "$CERT_FILE"; then
            echo -e "${GREEN} 复用已有证书：${CERT_FILE}${PLAIN}"
            chmod 600 "$KEY_FILE" 2>/dev/null
            return 0
        fi
        colorEcho $YELLOW " 已有证书未覆盖全部域名，将重新申请：$(domainsText)"
    fi

    colorEcho $BLUE " 未找到可用证书，开始申请..."
    stopNginx
    systemctl stop trojan-go 2>/dev/null
    sleep 2
    res=$(portOwner 80)
    res+="${res:+$'\n'}$(portOwner 443)"
    if [[ "${res}" != "" ]]; then
        echo -e "${RED} 其他进程占用了80或443端口，请先关闭再运行一键脚本${PLAIN}"
        echo " 端口占用信息如下："
        echo "${res}"
        exit 1
    fi

    "${APT_INSTALL_CMD[@]}" socat openssl
    "${APT_INSTALL_CMD[@]}" cron
    systemctl start cron
    systemctl enable cron

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s email=bangs@${DOMAIN}
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    for domain in "${DOMAINS[@]}"; do
        domain_args+=(-d "$domain")
    done
    ~/.acme.sh/acme.sh --issue "${domain_args[@]}" --keylength ec-256 \
        --pre-hook "systemctl stop nginx" --post-hook "systemctl restart nginx" --standalone
    [[ -f ~/.acme.sh/${DOMAIN}_ecc/ca.cer ]] || {
        colorEcho $RED " 获取证书失败"
        exit 1
    }
    CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
    KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        --reloadcmd "if [ -f /etc/systemd/system/trojan-go.service ]; then /bin/systemctl try-restart trojan-go >/dev/null 2>&1; fi"
    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || {
        colorEcho $RED " 获取证书失败"
        exit 1
    }
    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
}

writeRobots() {
    mkdir -p /usr/share/nginx/html
    if [[ "$ALLOW_SPIDER" = "n" ]]; then
        printf 'User-Agent: *\nDisallow: /\n' > /usr/share/nginx/html/robots.txt
    fi
}

configNginx() {
    local ROBOT_CONFIG user nginx_test_out server_names site_conf
    ensureDomains
    server_names="${DOMAINS[*]}"
    site_conf="${NGINX_CONF_PATH}${DOMAIN}.conf"
    mkdir -p /usr/share/nginx/html
    if [[ "$ALLOW_SPIDER" = "n" ]]; then
        ROBOT_CONFIG="    location = /robots.txt {}"
    else
        ROBOT_CONFIG=""
    fi
    if [[ ! -f /etc/nginx/nginx.conf.bak ]]; then
        mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    fi
    if ! id nginx >/dev/null 2>&1; then
        user="www-data"
    else
        user="nginx"
    fi
    cat > /etc/nginx/nginx.conf<<-EOF
user $user;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

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

    include /etc/nginx/conf.d/*.conf;
}
EOF

    mkdir -p "$NGINX_CONF_PATH"
    if [[ -n "$ORIGINAL_DOMAIN" && "$ORIGINAL_DOMAIN" != "$DOMAIN" ]]; then
        rm -f "${NGINX_CONF_PATH}${ORIGINAL_DOMAIN}.conf"
    fi
    if [[ "$PROXY_URL" = "" ]]; then
        cat > "$site_conf" <<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${server_names};
    root /usr/share/nginx/html;

    $ROBOT_CONFIG
}
EOF
    else
        cat > "$site_conf" <<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${server_names};
    root /usr/share/nginx/html;
    location / {
        proxy_ssl_server_name on;
        proxy_pass $PROXY_URL;
        proxy_set_header Accept-Encoding '';
        proxy_set_header Host $REMOTE_HOST;
        sub_filter "$REMOTE_HOST" "\$host";
        sub_filter_once off;
    }
    
    $ROBOT_CONFIG
}
EOF
    fi

    writeRobots

    if command -v nginx >/dev/null 2>&1 && ! nginx_test_out=$(nginx -t 2>&1); then
        colorEcho $RED " nginx 配置校验失败："
        echo "$nginx_test_out"
        exit 1
    fi
}

downloadTrojanPackage() {
    local url hits matched arch_re zip_urls tar_urls other_urls api apis tag
    local direct_url_tried="false"
    rm -f "$PACKAGE_FILE"

    if [[ -n "$TROJAN_ZIP_URL" ]]; then
        echo " 尝试下载：$TROJAN_ZIP_URL"
        if wget -q -T 30 -t 2 -O "$PACKAGE_FILE" "$TROJAN_ZIP_URL" && [[ -s "$PACKAGE_FILE" ]]; then
            DOWNLOAD_URL="$TROJAN_ZIP_URL"
            VERSION="$(tagFromUrl "$TROJAN_ZIP_URL")"
            return 0
        fi
        direct_url_tried="true"
        colorEcho $YELLOW " 该地址不可用，换下一个"
    fi

    buildDownloadCandidates
    for url in "${CANDIDATES[@]}"; do
        [[ -n "$url" ]] || continue
        [[ "$direct_url_tried" = "true" && "$url" = "$TROJAN_ZIP_URL" ]] && continue
        echo " 尝试下载：$url"
        if wget -q -T 30 -t 2 -O "$PACKAGE_FILE" "$url" && [[ -s "$PACKAGE_FILE" ]]; then
            DOWNLOAD_URL="$url"
            VERSION="$(tagFromUrl "$url")"
            return 0
        fi
        colorEcho $YELLOW " 该地址不可用，换下一个"
    done

    echo " 按命名规则没找到文件，改为从 release 资源列表自动识别..."
    arch_re=$(platformArchRegex) || {
        colorEcho $RED " 暂不支持的系统架构，无法自动识别安装包"
        exit 1
    }

    apis=()
    if [[ ${#TAGS[@]} -gt 0 ]]; then
        for tag in "${TAGS[@]}"; do
            apis+=("https://api.github.com/repos/${TROJAN_REPO}/releases/tags/${tag}")
        done
    else
        apis+=("https://api.github.com/repos/${TROJAN_REPO}/releases/latest")
    fi

    for api in "${apis[@]}"; do
        hits=$(apiAssetList "$api")
        if [[ -z "$hits" ]]; then
            colorEcho $YELLOW " 取不到资源列表（$(echo "$api" | sed 's|.*/releases/||')），试下一个版本"
            continue
        fi

        matched=$(echo "$hits" | grep -Ei "$arch_re" \
            | grep -Eiv 'windows|darwin|macos|freebsd|openbsd|netbsd|android|\.(md5|sha1|sha256|sha512|sig|asc|txt|json)$')
        if [[ -z "$matched" ]]; then
            colorEcho $YELLOW " 该 release 里没有匹配当前架构（$(uname -m)）的文件"
            if [[ "$api" = "${apis[${#apis[@]}-1]}" ]]; then
                echo "$hits" | sed 's|.*/||' | sed 's/^/   /'
            else
                colorEcho $YELLOW " 试下一个版本"
            fi
            continue
        fi

        zip_urls=$(echo "$matched" | grep -Ei '\.zip$')
        tar_urls=$(echo "$matched" | grep -Ei '\.(tar\.gz|tgz|tar\.xz|txz|tar\.bz2)$')
        other_urls=$(echo "$matched" | grep -Eiv '\.zip$|\.(tar\.gz|tgz|tar\.xz|txz|tar\.bz2)$')
        for url in $zip_urls $tar_urls $other_urls; do
            [[ -n "$url" ]] || continue
            echo " 尝试下载：$url"
            if wget -q -T 30 -t 2 -O "$PACKAGE_FILE" "$url" && [[ -s "$PACKAGE_FILE" ]]; then
                DOWNLOAD_URL="$url"
                VERSION="$(tagFromUrl "$url")"
                echo " 已匹配到：$(echo "$url" | sed 's|.*/||')"
                return 0
            fi
            colorEcho $YELLOW " 该地址不可用，换下一个"
        done
    done

    colorEcho $RED " go安装文件下载失败"
    printDownloadHelp
    exit 1
}

downloadFile() {
    downloadTrojanPackage
    echo " 下载地址：${DOWNLOAD_URL}"
    [[ -n "${VERSION}" ]] && echo " 版本：${VERSION}"

    rm -f "$HTML_ZIP_FILE"
    wget -q -T 30 -t 2 -O "$HTML_ZIP_FILE" "$HTML_ZIP_URL"
    if [[ ! -s "$HTML_ZIP_FILE" ]]; then
        colorEcho $YELLOW " 伪装站页面下载失败，将使用内置页面"
    fi
}

writeFallbackPage() {
    printf '%s\n' \
        '<!DOCTYPE html>' \
        '<html lang="en">' \
        '<head><meta charset="utf-8"><title>Welcome to nginx!</title></head>' \
        '<body><h1>Welcome to nginx!</h1></body>' \
        '</html>' > /usr/share/nginx/html/index.html
}

writeDefaultService() {
    cat > /etc/systemd/system/trojan-go.service <<-EOF
[Unit]
Description=trojan-go
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/bin/trojan-go -config /etc/trojan-go/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

extractPackage() {
    local f=$1 d=$2
    rm -rf "$d"
    mkdir -p "$d"
    if unzip -q -o "$f" -d "$d" >/dev/null 2>&1; then
        return 0
    fi
    if tar -xf "$f" -C "$d" >/dev/null 2>&1; then
        return 0
    fi
    if gzip -dc "$f" > "$d/${TROJAN_BINARY_NAME}" 2>/dev/null && [[ -s "$d/${TROJAN_BINARY_NAME}" ]]; then
        return 0
    fi
    rm -f "$d/${TROJAN_BINARY_NAME}"
    if xz -dc "$f" > "$d/${TROJAN_BINARY_NAME}" 2>/dev/null && [[ -s "$d/${TROJAN_BINARY_NAME}" ]]; then
        return 0
    fi
    rm -f "$d/${TROJAN_BINARY_NAME}"
    return 1
}

installTrojan() {
    local bin f g sig
    extractPackage "$PACKAGE_FILE" "$PACKAGE_DIR" || {
        colorEcho $RED " 安装包解压失败：$PACKAGE_FILE"
        exit 1
    }

    bin=$(find "$PACKAGE_DIR" -type f -name "${TROJAN_BINARY_NAME}" | head -n1)
    if [[ -z "$bin" ]]; then
        bin=$(find "$PACKAGE_DIR" -type f -iname "*${TROJAN_BINARY_NAME}*" ! -name '*.dat' | head -n1)
    fi
    if [[ -z "$bin" ]]; then
        bin=$(find "$PACKAGE_DIR" -type f -iname '*trojan*' -size +1M ! -name '*.dat' | head -n1)
    fi
    if [[ -z "$bin" ]]; then
        bin=$(find "$PACKAGE_DIR" -type f -size +1M ! -name '*.dat' ! -name '*.md' ! -name '*.txt' | head -n1)
    fi
    if [[ -z "$bin" ]]; then
        colorEcho $RED " 包里没找到主程序，可设置 TROJAN_BINARY_NAME 指定文件名。包内文件："
        find "$PACKAGE_DIR" -type f | sed 's/^/   /'
        exit 1
    fi
    sig=$(head -c 4 "$bin" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    if [[ -n "$sig" && "$sig" != "7f454c46" ]]; then
        colorEcho $RED " $(basename "$bin") 看起来不是 Linux 可执行文件"
        exit 1
    fi
    echo " 主程序：$(basename "$bin")"

    rm -rf /usr/share/nginx/html/*
    if [[ -s "$HTML_ZIP_FILE" ]]; then
        unzip -q -o "$HTML_ZIP_FILE" -d /usr/share/nginx/html/ || colorEcho $YELLOW " 伪装站页面解压失败"
    fi
    if [[ -z "$(ls -A /usr/share/nginx/html 2>/dev/null)" ]]; then
        colorEcho $YELLOW " 伪装站页面为空，已写入内置页面"
        writeFallbackPage
    fi
    chmod -R a+rX /usr/share/nginx/html 2>/dev/null
    writeRobots

    cp -f "$bin" /usr/bin/trojan-go
    chmod 755 /usr/bin/trojan-go

    for g in geoip.dat geosite.dat; do
        f=$(find "$PACKAGE_DIR" -type f -name "$g" | head -n1)
        [[ -n "$f" ]] && cp -f "$f" /etc/trojan-go/
    done
    f=$(find "$PACKAGE_DIR" -type f -name '*.service' | head -n1)
    if [[ -n "$f" && -s "$f" ]]; then
        cp -f "$f" /etc/systemd/system/trojan-go.service
        sed -i '/User=nobody/d' /etc/systemd/system/trojan-go.service
        sed -i -E 's#^ExecStart=.*#ExecStart=/usr/bin/trojan-go -config /etc/trojan-go/config.json#' \
            /etc/systemd/system/trojan-go.service
    fi
    if [[ ! -s /etc/systemd/system/trojan-go.service ]] ||
        ! grep -q '^ExecStart=' /etc/systemd/system/trojan-go.service; then
        writeDefaultService
    fi

    mkdir -p /etc/systemd/system/trojan-go.service.d
    cat > /etc/systemd/system/trojan-go.service.d/override.conf <<-EOF
[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF

    systemctl daemon-reload
    systemctl enable trojan-go >/dev/null 2>&1
    rm -rf "$PACKAGE_DIR"

    colorEcho $BLUE " go安装成功！"
}

configTrojan() {
    mkdir -p /etc/trojan-go
    local laddr
    laddr=$(listenAddr)
    cat > "$CONFIG_FILE" <<-EOF
{
"run_type": "server",
    "local_addr": "${laddr}",
    "local_port": ${PORT},
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "$PASSWORD"
        ],
    "log_level": 5,
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
    "fingerprint": "chrome"
  },
  "tcp": {
    "no_delay": true,
    "keep_alive": true,
    "prefer_ipv4": true
  },
  "mux": {
    "enabled": true,
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
    chmod 600 "$CONFIG_FILE"
    chmod 700 /etc/trojan-go 2>/dev/null
}

# 【已修复：显式加载内核模块 + 自动持久化规则】
addIptablesRules() {
    modprobe ip_tables 2>/dev/null || true
    modprobe iptable_filter 2>/dev/null || true

    local p
    for p in 80 443; do
        iptables -w -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null ||
            iptables -w -I INPUT -p tcp --dport "$p" -j ACCEPT
    done
    if [[ "$PORT" != "443" ]]; then
        iptables -w -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null ||
            iptables -w -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    fi

    if ! command -v netfilter-persistent >/dev/null 2>&1 && ! dpkg -l | grep -q iptables-persistent; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive "${APT_INSTALL_CMD[@]}" iptables-persistent >/dev/null 2>&1
    fi
    
    mkdir -p /etc/iptables
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    else
        iptables-save > /etc/iptables/rules.v4
    fi

    colorEcho $BLUE " 已添加并持久化 iptables 放行规则（重启后依然有效）"
}

setFirewall() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            if [[ "$PORT" != "443" ]]; then
                firewall-cmd --permanent --add-port="${PORT}/tcp"
            fi
            firewall-cmd --reload
        else
            addIptablesRules
        fi
    elif command -v iptables >/dev/null 2>&1; then
        addIptablesRules
    elif command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -qw active; then
            ufw allow http/tcp
            ufw allow https/tcp
            if [[ "$PORT" != "443" ]]; then
                ufw allow "${PORT}/tcp"
            fi
        fi
    else
        colorEcho $YELLOW " 未检测到 firewalld/iptables/ufw，跳过防火墙配置"
        colorEcho $YELLOW " 请确认云厂商安全组已放行 80、443 以及当前端口 ${PORT}/tcp"
    fi
}

install() {
    getData

    "${APT_CMD[@]}" clean
    "${APT_CMD[@]}" update

    "${APT_INSTALL_CMD[@]}" wget curl unzip tar openssl ca-certificates kmod
    "${APT_INSTALL_CMD[@]}" xz-utils cron

    for cmd in wget curl unzip tar openssl; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo -e " ${RED}${cmd} 安装失败，请检查网络${PLAIN}"
            exit 1
        fi
    done

    setBBR

    installNginx
    setFirewall
    getCert
    configNginx

    echo " 安装go..."
    downloadFile
    installTrojan
    configTrojan

    saveState

    start
    setAutoRestart
    showInfo
}

# 【已修复：增加 daemon-reload 与启动缓冲】
start() {
    local res port owner
    res=$(status)
    if [[ $res -lt 2 ]]; then
        echo -e "${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    systemctl daemon-reload
    sleep 1

    stopNginx
    startNginx
    systemctl restart trojan-go

    local i
    for i in 1 2 3 4 5; do
        sleep 1
        systemctl is-active --quiet trojan-go && break
    done
    if ! systemctl is-active --quiet trojan-go && grep -q '"local_addr": "::"' "$CONFIG_FILE"; then
        colorEcho $YELLOW " 启动失败，尝试改用 IPv4 监听(0.0.0.0)重试..."
        sed -i 's/"local_addr": "::"/"local_addr": "0.0.0.0"/' "$CONFIG_FILE"
        systemctl restart trojan-go
        for i in 1 2 3 4 5; do
            sleep 1
            systemctl is-active --quiet trojan-go && break
        done
    fi
    if ! systemctl is-active --quiet trojan-go; then
        colorEcho $RED " go启动失败，请检查配置或端口是否被占用！"
        port=$(grep local_port "$CONFIG_FILE" | cut -d: -f2 | tr -d \",' ')
        owner=$(portOwner "$port")
        if [[ -n "$owner" ]]; then
            echo " 端口占用信息："
            echo "$owner"
        fi
        colorEcho $YELLOW " 最近日志（最后 8 行）："
        journalctl -u trojan-go -n 8 --no-pager 2>/dev/null | sed 's/^/   /'
        colorEcho $YELLOW " 完整原因可用 journalctl -xen -u trojan-go 查看"
        return 1
    fi
    if ! systemctl is-active --quiet nginx; then
        colorEcho $RED " nginx未运行，伪装站可能不可用，请检查 nginx 配置"
    fi
    colorEcho $BLUE " go启动成功"
}

stop() {
    stopNginx
    systemctl stop trojan-go
    colorEcho $BLUE " go停止成功"
}

restart() {
    local res
    res=$(status)
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    stop
    start
}

reconfig() {
    local res
    res=$(status)
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    getData true
    getCert
    configTrojan
    setFirewall
    configNginx
    saveState
    stop
    start
    showInfo
}

showInfo() {
    local res
    res=$(status)
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    loadState >/dev/null 2>&1
    ensureDomains
    echo ""
    echo -n " go运行状态："
    statusText
    echo ""
    echo -e " ${BLUE}go配置文件: ${PLAIN} ${RED}${CONFIG_FILE}${PLAIN}"
    echo -e " ${BLUE}go配置信息：${PLAIN}"
    [[ -n "$VERSION" ]] && echo -e "   版本(version)：${RED}${VERSION}${PLAIN}"
    echo -e "   伪装域名/主机名(host)/SNI/peer名称：${RED}$(domainsText)${PLAIN}"
    if [[ ${#DOMAINS[@]} -gt 1 ]]; then
        echo -e "   域名模式：${RED}多域名${PLAIN}（共 ${#DOMAINS[@]} 个，主域名 ${DOMAIN}）"
    else
        echo -e "   域名模式：${RED}单域名${PLAIN}"
    fi
    echo -e "   端口(port)：${RED}$PORT${PLAIN}"
    echo -e "   密码(password)：${RED}$PASSWORD${PLAIN}"
    if [[ "$WS" = "true" ]]; then
        echo -e "   websocket：${RED}true${PLAIN}"
        echo -e "   ws路径(ws path)：${RED}${WSPATH}${PLAIN}"
    fi
    echo -e "   BBR 加速：$(bbrText)"
    echo ""
}

showCronStatus() {
    local status
    getAutoRestartStatus >/dev/null
    status=$AUTO_RESTART_STATUS
    echo ""
    echo -e "   ${BOLD}${BLUE}定时任务状态${PLAIN}"
    echo ""
    if [[ "$status" = "enabled" ]]; then
        echo -e "   ${BLUE}定时重启${PLAIN}：${GREEN}已启用${PLAIN}"
        echo -e "   ${BLUE}执行时间${PLAIN}：每天 ${CURRENT_RESTART_TIME}"
        echo -e "   ${BLUE}执行动作${PLAIN}：清理日志文件并重启 trojan-go 服务"
    else
        echo -e "   ${BLUE}定时重启${PLAIN}：${RED}已禁用${PLAIN}"
    fi
    echo ""
}

menu() {
    clear
    local cur_domain current_status

    echo ""
    echo -e "   ${BOLD}${RED}GO 一键脚本${PLAIN} ${BOLD}· trojan-go${PLAIN}"
    echo ""
    current_status=$(status)
    echo -n -e "   ${BLUE}运行状态${PLAIN}："
    statusText "$current_status"
    if [[ "$current_status" -ge 2 ]]; then
        cur_domain=$( loadState >/dev/null 2>&1; domainsText )
        echo -e "   ${BLUE}使用域名${PLAIN}：${RED}${cur_domain:-未记录}${PLAIN}"
    fi
    echo -e "   ${BLUE}BBR 加速${PLAIN}：$(bbrText)"
    echo ""
    echo -e "   ${GREEN}[1]${PLAIN}  安装 go"
    echo -e "   ${GREEN}[2]${PLAIN}  安装 go + WS"
    echo ""
    echo -e "   ${GREEN}[3]${PLAIN}  重启服务"
    echo -e "   ${GREEN}[4]${PLAIN}  定时重启管理"
    echo ""
    echo -e "   ${GREEN}[0]${PLAIN}  退出"
    echo ""

    read -p "  请选择操作 [0-4] : " answer
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
            restart
            ;;
        4)
            echo ""
            echo -e "   ${BOLD}${BLUE}定时重启管理${PLAIN}"
            echo ""
            echo -e "   ${GREEN}[1]${PLAIN}  开启定时重启"
            echo -e "   ${GREEN}[2]${PLAIN}  关闭定时重启"
            echo -e "   ${GREEN}[3]${PLAIN}  修改重启时间"
            echo -e "   ${GREEN}[4]${PLAIN}  查看定时任务状态"
            echo -e "   ${GREEN}[0]${PLAIN}  返回上级"
            echo ""
            read -p "  请选择 [0-4] : " sub_answer
            case $sub_answer in
                1)
                    getAutoRestartStatus >/dev/null
                    if [[ "$AUTO_RESTART_STATUS" = "enabled" ]]; then
                        echo -e " ${YELLOW}定时重启已开启，当前时间: $CURRENT_RESTART_TIME${PLAIN}"
                        read -p " 是否要修改时间？[y/n] " modify_ans
                        if [[ "${modify_ans,,}" = "y" ]]; then
                            modifyAutoRestartTime
                        fi
                    else
                        read -p " 请输入重启时间 (格式 HH:MM，默认 00:10)：" new_time
                        if [[ -z "$new_time" ]]; then
                            setAutoRestart
                        else
                            if [[ ! $new_time =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                                echo "错误：时间格式无效，使用默认时间 00:10"
                                setAutoRestart
                            else
                                setAutoRestart "$new_time"
                            fi
                        fi
                    fi
                    ;;
                2)
                    disableAutoRestart
                    ;;
                3)
                    modifyAutoRestartTime
                    ;;
                4)
                    showCronStatus
                    read -p " 按回车键返回..."
                    ;;
                *)
                    ;;
            esac
            ;;
        *)
            echo -e "$RED 请选择正确的操作！${PLAIN}"
            exit 1
            ;;
    esac
}

checkSystem

action="${1:-menu}"
case "$action" in
    menu|start|restart|stop|showInfo|reconfig)
        ${action}
        ;;
    *)
        echo " 参数错误"
        echo " 用法: $(basename "$0") [menu|start|restart|stop|showInfo|reconfig]"
        ;;
esac
