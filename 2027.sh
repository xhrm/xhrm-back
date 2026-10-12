#!/bin/bash
# go一键安装脚本


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
# 生效顺序：TROJAN_ZIP_URL > 按 TROJAN_ASSET_PATTERN 拼地址 > 从 release 资源列表自动识别
TROJAN_ZIP_URL=""                  # ① 直接指定下载地址（最优先，无视下面所有规则）
TROJAN_ASSET_PATTERN="trojan-go-linux-{arch}.zip"   # ② 文件名模板，支持 {arch} {os} {version}
TROJAN_ARCH_ALIAS=""               # ③ 仓库对架构的写法与默认不同时填，如 x86_64 / 64bit
TROJAN_VERSION=""                  # ④ 指定 tag（留空=用最新 release；模板含 {version} 时自动取最新 tag）
TROJAN_REPO="fregie/trojan-go"     # ⑤ GitHub 仓库，换 fork 时改这里
TROJAN_BINARY_NAME="trojan-go"     # ⑥ 解压后主程序名（自动识别失败时的兜底）
TROJAN_LISTEN_ADDR=""              # ⑦ 监听地址，留空=自动（有 IPv6 用 :: 双栈，否则用 0.0.0.0）
ENABLE_BBR="auto"                  # ⑧ BBR：auto=Debian 且内核≥4.9 时自动开启；yes=强制尝试；no=不处理
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

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

randStr() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-16}"
}

validDomain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

# 域名输入检查：自动去掉首尾空白和结尾多余的点，再逐类给出明确错误
# 通过时结果写入 DOMAIN_IN（已转小写），失败时原因写入 DOMAIN_ERR 并返回 1
normalizeDomain() {
    local raw="$1" bad
    raw="${raw#"${raw%%[![:space:]]*}"}"      # 去掉首部空白
    raw="${raw%"${raw##*[![:space:]]}"}"      # 去掉尾部空白（含粘贴带来的 \r）
    raw="${raw%.}"                            # 去掉结尾多余的点
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

    if command -v yum >/dev/null 2>&1; then
        PMT="yum"
        CMD_INSTALL="yum install -y "
    elif command -v apt >/dev/null 2>&1; then
        PMT="apt"
        CMD_INSTALL="apt install -y "
        export DEBIAN_FRONTEND=noninteractive   # 避免交互式提示卡住无人值守安装
    else
        echo -e " ${RED}不受支持的Linux系统${PLAIN}"
        exit 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e " ${RED}系统版本过低，请升级到最新版本${PLAIN}"
        exit 1
    fi
}

# ---------- 安装参数持久化 ----------
# 记录本次安装的参数，供"查看配置/修改配置"复用
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
EOF
    chmod 600 "$STATE_FILE"
}

# 从 config.json 读取字符串字段：confGet <字段名>
confGet() {
    grep -m1 "\"$1\"[[:space:]]*:" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f4
}

# 旧版本脚本装的机器没有状态文件，尝试从 config.json 反推参数
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

# trojan-go 监听地址：默认自动。有 IPv6 就用 "::"（双栈，v4/v6 都能连），
# 内核/云厂商把 IPv6 关掉时退回 "0.0.0.0"，否则 trojan-go 会因绑定失败起不来。
listenAddr() {
    if [[ -n "$TROJAN_LISTEN_ADDR" ]]; then
        echo "$TROJAN_LISTEN_ADDR"
    elif ip -6 addr show 2>/dev/null | grep -q 'inet6'; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

# ================= BBR 加速（Debian 默认开启） =================

# 当前是否已经在用 bbr
bbrEnabled() {
    [[ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" = "bbr" ]]
}

# BBR 状态文本（已开启带绿灯，未开启带红灯）；调用方自己加标签
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

# 开启 BBR：写 sysctl 配置并立即生效
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
# =============================================================

# 列出监听指定端口的进程（用于排查端口占用）
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

# ============ trojan-go 下载地址解析（适配不同仓库的命名规则） ============

# 本机架构在该仓库文件名里的写法：默认用 archAffix，可用 TROJAN_ARCH_ALIAS 覆盖
pkgArch() {
    if [[ -n "$TROJAN_ARCH_ALIAS" ]]; then
        echo "$TROJAN_ARCH_ALIAS"
    else
        archAffix
    fi
}

# 本机架构的多种常见写法（用于在 release 资源列表里自动挑选文件）
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

# 仓库最新 release 的 tag（tag 原样返回，GitHub 的下载路径就是 tag 原文）
apiLatestTag() {
    curl -fsSL --max-time 15 "https://api.github.com/repos/${TROJAN_REPO}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4
}

# 某个 release 里所有资源的下载地址，一行一个
apiAssetList() {
    local api="${1:-https://api.github.com/repos/${TROJAN_REPO}/releases/latest}"
    curl -fsSL --max-time 20 "$api" 2>/dev/null \
        | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4
}

# 按命名规则生成候选下载地址（TROJAN_ZIP_URL / TROJAN_ASSET_PATTERN）
buildDownloadCandidates() {
    CANDIDATES=()
    [[ -n "$TROJAN_ZIP_URL" ]] && CANDIDATES+=("$TROJAN_ZIP_URL")
    [[ -z "$TROJAN_ASSET_PATTERN" ]] && return 0

    local arch name tag
    arch=$(pkgArch) || {
        colorEcho $RED " 暂不支持的系统架构：$(uname -m)"
        colorEcho $YELLOW " 可在脚本顶部设置 TROJAN_ARCH_ALIAS（仓库的架构写法）或 TROJAN_ZIP_URL"
        exit 1
    }
    name="${TROJAN_ASSET_PATTERN//\{arch\}/$arch}"
    name="${name//\{os\}/linux}"

    if [[ "$name" == *"{version}"* ]]; then
        # 模板里带版本号：需要先取到 tag
        tag="${TROJAN_VERSION:-$(apiLatestTag)}"
        if [[ -z "$tag" ]]; then
            colorEcho $YELLOW " 文件名模板含 {version}，但没取到 release tag，改为自动识别资源列表"
            return 0
        fi
        VERSION="$tag"
        name="${name//\{version\}/$tag}"
        CANDIDATES+=("https://github.com/${TROJAN_REPO}/releases/download/${tag}/${name}")
    elif [[ -n "$TROJAN_VERSION" ]]; then
        VERSION="$TROJAN_VERSION"
        CANDIDATES+=("https://github.com/${TROJAN_REPO}/releases/download/${VERSION}/${name}")
    else
        # releases/latest/download/<文件名> 是 GitHub 的永久链接，不需要查 API
        CANDIDATES+=("https://github.com/${TROJAN_REPO}/releases/latest/download/${name}")
    fi
    return 0
}

# 下载地址都没命中时，打印怎么改
printDownloadHelp() {
    colorEcho $YELLOW " 可以这样指定下载来源（改脚本顶部即可）："
    echo "   1) TROJAN_ASSET_PATTERN=\"仓库的真实文件名模板\"，如 trojan-go-linux-{arch}.tar.gz"
    echo "      不同仓库架构写法不同，可配合 TROJAN_ARCH_ALIAS=\"x86_64\" 这类覆盖"
    echo "   2) 或直接把地址写进 TROJAN_ZIP_URL=\"https://.../xxx.zip\""
    echo "   3) 或改 TROJAN_REPO / TROJAN_VERSION 指向实际仓库与版本"
    echo "   当前架构：$(uname -m)   模板中的架构取值：$(pkgArch 2>/dev/null)"
}

archAffix() {
    case "${1:-"$(uname -m)"}" in
        i686|i386)
            echo '386'
        ;;
        x86_64|amd64)
            echo 'amd64'
        ;;
        *armv7*|armv6l)
            echo 'armv7'
        ;;
        *armv8*|aarch64)
            echo 'armv8'
        ;;
        *armv6*)
            echo 'armv6'
        ;;
        *arm*)
            echo 'arm'
        ;;
        *mips64le*)
            echo 'mips64le'
        ;;
        *mips64*)
            echo 'mips64'
        ;;
        *mipsle*)
            echo 'mipsle-softfloat'
        ;;
        *mips*)
            echo 'mips-softfloat'
        ;;
        *)
            return 1
        ;;
    esac

    return 0
}

getData() {
    echo ""
    can_change=$1
    if [[ "$can_change" != "yes" ]]; then
        while true
        do
            read -p " 请输入伪装域名：" domain_input
            if normalizeDomain "$domain_input"; then
                DOMAIN="$DOMAIN_IN"
                break
            fi
            echo -e " ${RED}${DOMAIN_ERR}${PLAIN}"
        done
        colorEcho $BLUE " 伪装域名(host)：$DOMAIN"

        # 密码自动随机生成，不需要手动设置
        PASSWORD=$(randStr 16)
    else
        # 改配置：读取已有参数，只更新需要变化的项
        if ! loadState || [[ -z "$DOMAIN" ]]; then
            colorEcho $RED " 读取已有配置失败，请重新安装。"
            exit 1
        fi
        colorEcho $BLUE " 当前伪装域名(host)：$DOMAIN"
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

    if [[ ${WS} = "true" ]]; then
        echo ""
        while true
        do
            read -p " 请输入伪装路径，以/开头(不懂请直接回车)${WSPATH:+[默认：$WSPATH]}：" wspath_input
            if [[ -z "${wspath_input}" ]]; then
                if [[ -z "$WSPATH" ]]; then
                    len=`shuf -i 5-12 -n 1`
                    WSPATH="/$(randStr $len)"
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

    REMOTE_HOST=`echo ${PROXY_URL} | cut -d/ -f3`
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
        ALLOW_SPIDER="n"    # 全新安装默认不允许爬虫
    fi
    echo ""

    colorEcho $BLUE " 允许搜索引擎：$ALLOW_SPIDER"
}

# ================= 定时重启功能（trojan-go服务） =================
DEFAULT_RESTART_TIME="00:10"
SERVICE_NAME="trojan-go"
LOG_FILE="/etc/trojan-go/log.txt"
CRON_MARKER="auto_restart_$SERVICE_NAME"
CRON_FILE="/etc/cron.d/trojan-go-autorestart"

# 获取当前定时重启状态
getAutoRestartStatus() {
    if [[ -f "$CRON_FILE" ]] && grep -q "$CRON_MARKER" "$CRON_FILE"; then
        echo "enabled"
        local line=$(grep "$CRON_MARKER" "$CRON_FILE")
        local minute=$(echo "$line" | awk '{print $1}')
        local hour=$(echo "$line" | awk '{print $2}')
        printf -v CURRENT_RESTART_TIME "%02d:%02d" "$hour" "$minute"
    else
        echo "disabled"
        CURRENT_RESTART_TIME=""
    fi
}

# 设置或更新定时重启任务
setAutoRestart() {
    local time_str="${1:-$DEFAULT_RESTART_TIME}"
    local hour=$(echo "$time_str" | cut -d: -f1)
    local minute=$(echo "$time_str" | cut -d: -f2)
    
    hour=${hour#0}
    minute=${minute#0}
    [[ -z "$hour" ]] && hour=0
    [[ -z "$minute" ]] && minute=10

    # 确保 cron 服务启动
    if systemctl list-unit-files | grep -qE '^crond\.service'; then
        CRON_SERVICE="crond"
    elif systemctl list-unit-files | grep -qE '^cron\.service'; then
        CRON_SERVICE="cron"
    else
        echo "未找到 cron 服务，请确认已安装 cron。"
        return 1
    fi

    if ! systemctl is-active --quiet "$CRON_SERVICE"; then
        echo "正在启动 $CRON_SERVICE 服务..."
        systemctl start "$CRON_SERVICE"
        systemctl enable "$CRON_SERVICE" >/dev/null 2>&1 || true
    fi

    # 写入 /etc/cron.d 文件
    echo "$minute $hour * * * root rm -f $LOG_FILE; /bin/systemctl restart $SERVICE_NAME # $CRON_MARKER" > $CRON_FILE
    chmod 644 $CRON_FILE

    echo -e " ${BLUE}定时任务已设置：每天 $(printf '%02d:%02d' "$hour" "$minute") 清理日志并自动重启 $SERVICE_NAME${PLAIN}"
}

# 关闭定时重启
disableAutoRestart() {
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        echo -e " ${BLUE}服务定时重启已关闭${PLAIN}"
    else
        echo -e " ${YELLOW}服务定时重启未启用${PLAIN}"
    fi
}

# 修改定时重启时间
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
# ================================================

installNginx() {
    echo ""
    colorEcho $BLUE " 安装nginx..."
    if [[ "$PMT" = "yum" ]]; then
        $CMD_INSTALL epel-release
        if [[ "$?" != "0" ]]; then
            echo '[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true' > /etc/yum.repos.d/nginx.repo
        fi
    fi
    $CMD_INSTALL nginx
    if [[ "$?" != "0" ]]; then
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

# 校验证书与私钥是否匹配，并且证书未过期
certKeyMatch() {
    local cert=$1 key=$2 pub_cert pub_key
    [[ -f "$cert" && -f "$key" ]] || return 1
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    pub_cert=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum)
    pub_key=$(openssl pkey -in "$key" -pubout -outform der -passin pass: 2>/dev/null | sha256sum)
    [[ -n "$pub_cert" && "$pub_cert" = "$pub_key" ]]
}

# 证书里的域名是否覆盖指定域名（仅用于提示，不做阻断）
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
            [[ "$domain" == *".$suffix" ]] && return 0
        fi
    done <<< "$all"
    return 1
}

# 在 /root 下寻找可用的本地证书/私钥对：优先同名配对，其次目录内唯一的 .key
# 找到时设置 LOCAL_CERT / LOCAL_KEY 并返回 0
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
            LOCAL_CERT="$p"
            LOCAL_KEY="$k"
            return 0
        fi
        colorEcho $YELLOW " 跳过不可用的证书对：$p / $k"
    done
    return 1
}

getCert() {
    mkdir -p /etc/trojan-go

    # 1) 本地证书优先（/root 下的 .pem/.key）
    if findLocalCert; then
        echo -e "${GREEN} 检测到本地证书：${LOCAL_CERT}${PLAIN}"
        echo -e "${GREEN} 对应私钥：${LOCAL_KEY}${PLAIN}"
        openssl x509 -in "$LOCAL_CERT" -noout -subject 2>/dev/null | sed 's/^subject=/ 证书主体：/'
        if ! certCoversDomain "$LOCAL_CERT" "$DOMAIN"; then
            colorEcho $YELLOW " 注意：证书看起来不包含域名 ${DOMAIN}，请自行确认。"
        fi
        CERT_FILE="/etc/trojan-go/${DOMAIN}.pem"
        KEY_FILE="/etc/trojan-go/${DOMAIN}.key"
        cp -f "$LOCAL_CERT" "$CERT_FILE"
        cp -f "$LOCAL_KEY" "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        chmod 600 "$KEY_FILE"
        return 0
    fi

    # 2) 已有可用证书则直接复用，不重新申请
    if certKeyMatch "$CERT_FILE" "$KEY_FILE"; then
        echo -e "${GREEN} 复用已有证书：${CERT_FILE}${PLAIN}"
        chmod 600 "$KEY_FILE" 2>/dev/null
        return 0
    fi

    # 3) 都没有才通过 acme.sh 申请
    colorEcho $BLUE " 未找到可用证书，开始申请..."
    stopNginx
    systemctl stop trojan-go 2>/dev/null
    sleep 2
    res="$(portOwner 80)$(portOwner 443)"
    if [[ "${res}" != "" ]]; then
        echo -e "${RED} 其他进程占用了80或443端口，请先关闭再运行一键脚本${PLAIN}"
        echo " 端口占用信息如下："
        echo "${res}"
        exit 1
    fi

    $CMD_INSTALL socat openssl
    if [[ "$PMT" = "yum" ]]; then
        $CMD_INSTALL cronie
        systemctl start crond
        systemctl enable crond
    else
        $CMD_INSTALL cron
        systemctl start cron
        systemctl enable cron
    fi

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s email=bangs@bangs.cc
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --keylength ec-256 \
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
    [[ -f $CERT_FILE && -f $KEY_FILE ]] || {
        colorEcho $RED " 获取证书失败"
        exit 1
    }
    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
}


# 生成 robots.txt。必须在站点文件解压完成后调用，否则会被解压出来的文件覆盖
writeRobots() {
    mkdir -p /usr/share/nginx/html
    if [[ "$ALLOW_SPIDER" = "n" ]]; then
        printf 'User-Agent: *\nDisallow: /\n' > /usr/share/nginx/html/robots.txt
    fi
}

configNginx() {
    mkdir -p /usr/share/nginx/html
    if [[ "$ALLOW_SPIDER" = "n" ]]; then
        ROBOT_CONFIG="    location = /robots.txt {}"
    else
        ROBOT_CONFIG=""
    fi
    if [[ ! -f /etc/nginx/nginx.conf.bak ]]; then
        mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    fi
    res=`id nginx 2>/dev/null`
    if [[ "$?" != "0" ]]; then
        user="www-data"
    else
        user="nginx"
    fi
    cat > /etc/nginx/nginx.conf<<-EOF
user $user;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

# Load dynamic modules. See /usr/share/doc/nginx/README.dynamic.

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

    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;
}
EOF

    mkdir -p $NGINX_CONF_PATH
    if [[ "$PROXY_URL" = "" ]]; then
        cat > $NGINX_CONF_PATH${DOMAIN}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;

    $ROBOT_CONFIG
}
EOF
    else
        cat > $NGINX_CONF_PATH${DOMAIN}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;
    location / {
        proxy_ssl_server_name on;
        proxy_pass $PROXY_URL;
        proxy_set_header Accept-Encoding '';
        proxy_set_header Host $REMOTE_HOST;
        sub_filter "$REMOTE_HOST" "$DOMAIN";
        sub_filter_once off;
    }
    
    $ROBOT_CONFIG
}
EOF
    fi

    writeRobots

    # 写完立即校验，避免生成非法配置导致伪装站直接不可用
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_out=$(nginx -t 2>&1); then
        colorEcho $RED " nginx 配置校验失败："
        echo "$nginx_test_out"
        exit 1
    fi
}

# 下载 trojan-go 包：先按命名规则拼地址，失败再从 release 资源列表自动识别
downloadTrojanPackage() {
    local url hits matched arch_re zip_urls tar_urls other_urls
    rm -f /tmp/${ZIP_FILE}.pkg

    buildDownloadCandidates
    for url in "${CANDIDATES[@]}"; do
        [[ -n "$url" ]] || continue
        echo " 尝试下载：$url"
        if wget -q -T 30 -t 2 -O /tmp/${ZIP_FILE}.pkg "$url" && [[ -s /tmp/${ZIP_FILE}.pkg ]]; then
            DOWNLOAD_URL="$url"
            return 0
        fi
        colorEcho $YELLOW " 该地址不可用，换下一个"
    done

    # 走到这里说明文件名规则和我们猜的不一样，去 release 资源列表里挑
    echo " 按命名规则没找到文件，改为从 release 资源列表自动识别..."
    arch_re=$(platformArchRegex) || {
        colorEcho $RED " 暂不支持的系统架构，无法自动识别安装包"
        exit 1
    }
    if [[ -n "$VERSION" ]]; then
        hits=$(apiAssetList "https://api.github.com/repos/${TROJAN_REPO}/releases/tags/${VERSION}")
    else
        hits=$(apiAssetList)
    fi
    if [[ -z "$hits" ]]; then
        colorEcho $RED " 无法获取 ${TROJAN_REPO} 的 release 资源列表（仓库名是否正确？GitHub API 是否被限流？）"
        printDownloadHelp
        exit 1
    fi

    # 先按架构筛，再排除其它系统与校验文件
    matched=$(echo "$hits" | grep -Ei "$arch_re" \
        | grep -Eiv 'windows|darwin|macos|freebsd|openbsd|netbsd|android|\.(md5|sha1|sha256|sha512|sig|asc|txt|json)$')
    if [[ -z "$matched" ]]; then
        colorEcho $RED " 资源列表里没有匹配当前架构（$(uname -m)）的文件，该 release 包含："
        echo "$hits" | sed 's|.*/||' | sed 's/^/   /'
        printDownloadHelp
        exit 1
    fi

    # 下载顺序：zip 优先，其次 tar 包，最后其它压缩格式
    zip_urls=$(echo "$matched" | grep -Ei '\.zip$')
    tar_urls=$(echo "$matched" | grep -Ei '\.(tar\.gz|tgz|tar\.xz|txz|tar\.bz2)$')
    other_urls=$(echo "$matched" | grep -Eiv '\.zip$|\.(tar\.gz|tgz|tar\.xz|txz|tar\.bz2)$')
    for url in $zip_urls $tar_urls $other_urls; do
        [[ -n "$url" ]] || continue
        echo " 尝试下载：$url"
        if wget -q -T 30 -t 2 -O /tmp/${ZIP_FILE}.pkg "$url" && [[ -s /tmp/${ZIP_FILE}.pkg ]]; then
            DOWNLOAD_URL="$url"
            echo " 已匹配到：$(echo "$url" | sed 's|.*/||')"
            return 0
        fi
        colorEcho $YELLOW " 该地址不可用，换下一个"
    done

    colorEcho $RED " go安装文件下载失败"
    printDownloadHelp
    exit 1
}

downloadFile() {
    downloadTrojanPackage
    echo " 下载地址：${DOWNLOAD_URL}"

    rm -f /tmp/html.zip
    wget -q -T 30 -t 2 -O /tmp/html.zip "$HTML_ZIP_URL"
    if [[ ! -s /tmp/html.zip ]]; then
        colorEcho $YELLOW " 伪装站页面下载失败，将使用内置页面"
    fi
}

# 下载不到伪装站页面时的兜底页面，避免站点空白
writeFallbackPage() {
    printf '%s\n' \
        '<!DOCTYPE html>' \
        '<html lang="en">' \
        '<head><meta charset="utf-8"><title>Welcome to nginx!</title></head>' \
        '<body><h1>Welcome to nginx!</h1></body>' \
        '</html>' > /usr/share/nginx/html/index.html
}

# release 包结构变化时的兜底 service 文件
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

# 解压安装包：zip / tar.gz / tar.xz / 单文件压缩都能处理
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
    # 有些仓库只发了一个压缩过的二进制文件
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
    local bin f g
    extractPackage "/tmp/${ZIP_FILE}.pkg" "/tmp/${ZIP_FILE}" || {
        colorEcho $RED " 安装包解压失败（不认识的压缩格式？）：/tmp/${ZIP_FILE}.pkg"
        exit 1
    }

    # 找主程序：先精确名，再名字里带 trojan，最后按体积兜底
    bin=$(find "/tmp/${ZIP_FILE}" -type f -name "${TROJAN_BINARY_NAME}" | head -n1)
    if [[ -z "$bin" ]]; then
        bin=$(find "/tmp/${ZIP_FILE}" -type f -iname "*${TROJAN_BINARY_NAME}*" ! -name '*.dat' | head -n1)
    fi
    if [[ -z "$bin" ]]; then
        bin=$(find "/tmp/${ZIP_FILE}" -type f -iname '*trojan*' -size +1M ! -name '*.dat' | head -n1)
    fi
    if [[ -z "$bin" ]]; then
        bin=$(find "/tmp/${ZIP_FILE}" -type f -size +1M ! -name '*.dat' ! -name '*.md' ! -name '*.txt' | head -n1)
    fi
    if [[ -z "$bin" ]]; then
        colorEcho $RED " 包里没找到主程序，可设置 TROJAN_BINARY_NAME 指定文件名。包内文件："
        find "/tmp/${ZIP_FILE}" -type f | sed 's/^/   /'
        exit 1
    fi
    # 确认选中的确实是 Linux 可执行文件（ELF），避免把说明文档/数据文件当成程序
    sig=$(head -c 4 "$bin" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    if [[ -n "$sig" && "$sig" != "7f454c46" ]]; then
        colorEcho $RED " $(basename "$bin") 看起来不是 Linux 可执行文件，可能选错了，包内文件："
        find "/tmp/${ZIP_FILE}" -type f | sed 's/^/   /'
        colorEcho $YELLOW " 可设置 TROJAN_BINARY_NAME 指定正确的文件名"
        exit 1
    fi
    echo " 主程序：$(basename "$bin")"

    rm -rf /usr/share/nginx/html/*
    if [[ -s /tmp/html.zip ]]; then
        unzip -q -o /tmp/html.zip -d /usr/share/nginx/html/ || colorEcho $YELLOW " 伪装站页面解压失败"
    fi
    if [[ -z "$(ls -A /usr/share/nginx/html 2>/dev/null)" ]]; then
        colorEcho $YELLOW " 伪装站页面为空，已写入内置页面"
        writeFallbackPage
    fi
    # 保证 nginx（Debian 下是 www-data）能读，避免解压出来的文件权限过紧导致 403
    chmod -R a+rX /usr/share/nginx/html 2>/dev/null
    # 必须在页面解压完成之后再写 robots.txt，否则会被覆盖
    writeRobots

    cp -f "$bin" /usr/bin/trojan-go
    chmod 755 /usr/bin/trojan-go

    # geoip/geosite 与 service 文件都是可选件，有就拷
    for g in geoip.dat geosite.dat; do
        f=$(find "/tmp/${ZIP_FILE}" -type f -name "$g" | head -n1)
        [[ -n "$f" ]] && cp -f "$f" /etc/trojan-go/
    done
    f=$(find "/tmp/${ZIP_FILE}" -type f -name '*.service' | head -n1)
    if [[ -n "$f" ]]; then
        cp -f "$f" /etc/systemd/system/trojan-go.service
        sed -i '/User=nobody/d' /etc/systemd/system/trojan-go.service
    else
        writeDefaultService
    fi

    # 崩溃自动拉起，并提高文件描述符上限
    mkdir -p /etc/systemd/system/trojan-go.service.d
    cat > /etc/systemd/system/trojan-go.service.d/override.conf <<-EOF
[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF

    systemctl daemon-reload
    systemctl enable trojan-go >/dev/null 2>&1
    rm -rf /tmp/${ZIP_FILE}

    colorEcho $BLUE " go安装成功！"
}

configTrojan() {
    mkdir -p /etc/trojan-go
    local laddr
    laddr=$(listenAddr)
    cat > $CONFIG_FILE <<-EOF
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
    # 配置文件里有明文密码，收紧权限
    chmod 600 "$CONFIG_FILE"
    chmod 700 /etc/trojan-go 2>/dev/null
}

setSelinux() {
    if [[ -s /etc/selinux/config ]] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
        setenforce 0
    fi
}

# 添加 iptables 放行规则：先用 -C 判断是否已存在，避免重复插入
addIptablesRules() {
    local p
    for p in 80 443; do
        iptables -w -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null ||
            iptables -w -I INPUT -p tcp --dport $p -j ACCEPT
    done
    if [[ "$PORT" != "443" ]]; then
        iptables -w -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null ||
            iptables -w -I INPUT -p tcp --dport ${PORT} -j ACCEPT
    fi
    colorEcho $YELLOW " 已添加 iptables 放行规则（重启后可能失效，需自行持久化）"
}

setFirewall() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            if [[ "$PORT" != "443" ]]; then
                firewall-cmd --permanent --add-port=${PORT}/tcp
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
                ufw allow ${PORT}/tcp
            fi
        fi
    else
        colorEcho $YELLOW " 未检测到 firewalld/iptables/ufw，跳过防火墙配置"
        colorEcho $YELLOW " 请确认云厂商安全组已放行 80、443 以及当前端口 ${PORT}/tcp"
    fi
}



install() {
    # 在脚本开始时检查系统版本
    check_system_version() {
        if grep -q "CentOS Linux release 7" /etc/centos-release 2>/dev/null; then
            echo "检测到系统为CentOS 7，执行预处理命令..."
            curl -fsSL https://autoinstall.plesk.com/PSA_18.0.62/examiners/repository_check.sh | bash -s -- update >/dev/null
            if [[ $? -ne 0 ]]; then
                echo "预处理命令执行失败"
                exit 1
            fi
        else
            echo "系统不是CentOS 7，继续执行脚本..."
        fi
    }

    # 调用系统版本检测函数
    check_system_version

    getData

    if [[ "$PMT" = "apt" ]]; then
        $PMT clean
        $PMT update
    else
        $PMT clean all
    fi

    # 只装真正用得到的：下载、解压、证书、定时任务
    $CMD_INSTALL wget curl unzip tar openssl ca-certificates kmod
    if [[ "$PMT" = "yum" ]]; then
        $CMD_INSTALL xz cronie
    else
        $CMD_INSTALL xz-utils cron
    fi

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

    # 记录本次安装的参数，供"查看配置/修改配置"复用
    saveState

    setSelinux

    start
    setAutoRestart
    showInfo

}

start() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e "${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    stopNginx
    startNginx
    systemctl restart trojan-go

    local i
    for i in 1 2 3 4 5; do
        sleep 1
        systemctl is-active --quiet trojan-go && break
    done
    if ! systemctl is-active --quiet trojan-go && grep -q '"local_addr": "::"' "$CONFIG_FILE"; then
        # 常见坑：内核/云厂商关了 IPv6，绑定 "::" 会直接失败，退回 IPv4 再试一次
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
        port=`grep local_port $CONFIG_FILE|cut -d: -f2| tr -d \",' '`
        owner=$(portOwner "$port")
        if [[ -n "$owner" ]]; then
            echo " 端口占用信息："
            echo "$owner"
        fi
        colorEcho $YELLOW " 可用 journalctl -xen -u trojan-go 查看失败原因"
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
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    stop
    start
}

reconfig() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    getData true      # 读取已有参数，只更新需要变化的项
    getCert           # 本地证书 > 已有证书 > acme 申请；失败时不改动现有配置
    configTrojan
    setFirewall
    configNginx
    saveState
    stop
    start
    showInfo
}


showInfo() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        echo -e " ${RED}go未安装，请先安装！${PLAIN}"
        return
    fi

    # 优先读状态文件；旧版本脚本装的机器回退到解析 config.json
    loadState >/dev/null 2>&1
    echo ""
    echo -n " go运行状态："
    statusText
    echo ""
    echo -e " ${BLUE}go配置文件: ${PLAIN} ${RED}${CONFIG_FILE}${PLAIN}"
    echo -e " ${BLUE}go配置信息：${PLAIN}"
    echo -e "   伪装域名/主机名(host)/SNI/peer名称：${RED}$DOMAIN${PLAIN}"
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
    local status=$(getAutoRestartStatus)
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
    local cur_domain

    echo ""
    echo -e "   ${BOLD}${RED}GO 一键脚本${PLAIN} ${BOLD}· trojan-go${PLAIN}"
    echo ""
    echo -n -e "   ${BLUE}运行状态${PLAIN}："
    statusText
    if [[ "$(status)" -ge 2 ]]; then
        cur_domain=$( loadState >/dev/null 2>&1; echo "$DOMAIN" )
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
            # 定时重启管理子菜单
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
                    if [[ "$(getAutoRestartStatus)" = "enabled" ]]; then
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

action=$1
[[ -z $1 ]] && action=menu
# 菜单里已精简，但 start/stop/showInfo/reconfig 仍可从命令行直接调用，例如：
#   bash 26.sh reconfig     bash 26.sh showInfo
case "$action" in
    menu|start|restart|stop|showInfo|reconfig)
        ${action}
        ;;
    *)
        echo " 参数错误"
        echo " 用法: `basename $0` [menu|start|restart|stop|showInfo|reconfig]"
        ;;
esac
