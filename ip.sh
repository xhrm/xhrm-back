#!/bin/bash

#=============================================================================
# IP封杀脚本 - 基于日志分析自动封禁异常IP
# 适用系统: CentOS 7/8/9, Debian 10/11/12
# 版本: 2.0
# 封禁策略: 永久封禁，阻止所有端口和协议
#=============================================================================

set -o pipefail

#=============================================================================
# 配置参数
#=============================================================================
LOG_FILE="/etc/trojan-go/log.txt"
SCRIPT_NAME="ip-blocker"
SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}.sh"
SERVICE_NAME="${SCRIPT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_DIR="/etc/${SCRIPT_NAME}"
BLOCKED_IPS_FILE="${CONFIG_DIR}/blocked_ips.txt"
BLOCKED_USERS_FILE="${CONFIG_DIR}/blocked_users.txt"
MONITOR_STATUS_FILE="${CONFIG_DIR}/monitor_status"
CONFIG_FILE="${CONFIG_DIR}/config.conf"
BLOCK_LOG_FILE="${CONFIG_DIR}/block.log"
LOCK_FILE="${CONFIG_DIR}/monitor.lock"

# 默认值
DEFAULT_IP_THRESHOLD=3
DEFAULT_CHECK_INTERVAL=10

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

#=============================================================================
# 基础函数
#=============================================================================

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            centos|rhel|fedora|rocky|alma)
                OS="centos"
                ;;
            debian|ubuntu|raspbian)
                OS="debian"
                ;;
            *)
                echo -e "${RED}不支持的系统: $ID${NC}"
                exit 1
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        echo -e "${RED}无法检测系统类型${NC}"
        exit 1
    fi
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用root权限运行此脚本${NC}"
        exit 1
    fi
}

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    IP_THRESHOLD=${IP_THRESHOLD:-$DEFAULT_IP_THRESHOLD}
    CHECK_INTERVAL=${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}
}

# 保存配置
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
IP_THRESHOLD=${IP_THRESHOLD}
CHECK_INTERVAL=${CHECK_INTERVAL}
LOG_FILE="${LOG_FILE}"
EOF
}

# 写入封禁日志
write_block_log() {
    local type="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$CONFIG_DIR"
    echo "[${timestamp}] [${type}] ${message}" >> "$BLOCK_LOG_FILE"
}

# 获取运行时长
get_uptime() {
    if [ -f "$BLOCK_LOG_FILE" ]; then
        local start_time=$(grep '\[启动\]' "$BLOCK_LOG_FILE" | tail -1 | grep -oP '^\[\K[^\]]+')
        if [ -n "$start_time" ]; then
            local start_ts=$(date -d "$start_time" +%s 2>/dev/null)
            local now_ts=$(date +%s)
            if [ -n "$start_ts" ]; then
                local diff=$((now_ts - start_ts))
                local days=$((diff / 86400))
                local hours=$(((diff % 86400) / 3600))
                local minutes=$(((diff % 3600) / 60))
                if [ $days -gt 0 ]; then
                    echo "${days}天${hours}小时${minutes}分钟"
                elif [ $hours -gt 0 ]; then
                    echo "${hours}小时${minutes}分钟"
                else
                    echo "${minutes}分钟"
                fi
                return
            fi
        fi
    fi
    echo "未知"
}

# 获取总封禁次数
get_total_blocks() {
    if [ -f "$BLOCK_LOG_FILE" ]; then
        grep -c '\[封禁\]' "$BLOCK_LOG_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

#=============================================================================
# 依赖安装
#=============================================================================

install_dependencies() {
    echo -e "${YELLOW}正在检测并安装依赖...${NC}"
    
    local missing_pkgs=""
    
    case $OS in
        centos)
            if ! command -v iptables &>/dev/null; then
                missing_pkgs="$missing_pkgs iptables"
            fi
            if ! command -v crontab &>/dev/null; then
                missing_pkgs="$missing_pkgs cronie"
            fi
            if ! command -v grep &>/dev/null; then
                missing_pkgs="$missing_pkgs grep"
            fi
            if ! command -v awk &>/dev/null; then
                missing_pkgs="$missing_pkgs gawk"
            fi
            
            if [ -n "$missing_pkgs" ]; then
                echo -e "${YELLOW}安装缺失的包:${missing_pkgs}${NC}"
                yum install -y $missing_pkgs > /dev/null 2>&1
            fi
            ;;
        debian)
            if ! command -v iptables &>/dev/null; then
                missing_pkgs="$missing_pkgs iptables"
            fi
            if ! command -v crontab &>/dev/null; then
                missing_pkgs="$missing_pkgs cron"
            fi
            if ! command -v grep &>/dev/null; then
                missing_pkgs="$missing_pkgs grep"
            fi
            if ! command -v awk &>/dev/null; then
                missing_pkgs="$missing_pkgs gawk"
            fi
            
            if [ -n "$missing_pkgs" ]; then
                echo -e "${YELLOW}安装缺失的包:${missing_pkgs}${NC}"
                apt-get update > /dev/null 2>&1
                apt-get install -y $missing_pkgs > /dev/null 2>&1
            fi
            ;;
    esac
    
    echo -e "${GREEN}依赖检测完成${NC}"
}

#=============================================================================
# 文件初始化
#=============================================================================

init_files() {
    mkdir -p "$CONFIG_DIR"
    touch "$BLOCKED_IPS_FILE"
    touch "$BLOCKED_USERS_FILE"
    touch "$BLOCK_LOG_FILE"
    echo "enabled" > "$MONITOR_STATUS_FILE"
    
    # 复制脚本到系统目录
    if [ "$(readlink -f "$0")" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
}

#=============================================================================
# 日志解析函数
#=============================================================================

# 获取最近N分钟的日志
get_recent_logs() {
    local minutes_ago="${1:-10}"
    local current_ts=$(date +%s)
    local target_ts=$((current_ts - minutes_ago * 60))
    local result=""
    
    if [ -f "$LOG_FILE" ]; then
        while IFS= read -r line; do
            # 匹配时间戳格式: [DEBUG] YYYY/MM/DD HH:MM:SS
            if [[ $line =~ \[DEBUG\]\ ([0-9]{4}/[0-9]{2}/[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
                local log_time="${BASH_REMATCH[1]}"
                # 转换为Unix时间戳
                local log_ts=$(date -d "${log_time//\//-}" +%s 2>/dev/null)
                if [ $? -eq 0 ] && [ "$log_ts" -ge "$target_ts" ]; then
                    result+="$line"$'\n'
                fi
            fi
        done < "$LOG_FILE"
    fi
    
    echo "$result"
}

# 从日志中提取包含用户信息的行
extract_user_lines() {
    local log_content="$1"
    # 只提取包含 "user [64位hash] from IP" 模式的行
    echo "$log_content" | grep -E 'user [a-f0-9]{64} from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

# 提取所有唯一用户hash
extract_users() {
    local log_content="$1"
    echo "$log_content" | grep -oP 'user \K[a-f0-9]{64}' | sort -u
}

# 提取指定用户的所有IP
extract_user_ips() {
    local log_content="$1"
    local user="$2"
    echo "$log_content" | grep "user ${user}" | grep -oP 'from \K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u
}

#=============================================================================
# IP封禁管理 - 永久封禁，阻止所有端口和协议
#=============================================================================

# 封禁单个IP（永久封禁，阻止所有端口/协议）
block_ip() {
    local ip="$1"
    local user="$2"
    local reason="$3"
    
    # 检查IP格式
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    
    # 排除本地回环地址
    if [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "0.0.0.0" ]]; then
        return 1
    fi
    
    # 检查是否已封禁
    if grep -q "^${ip}$" "$BLOCKED_IPS_FILE" 2>/dev/null; then
        return 2
    fi
    
    # 添加到封禁列表
    echo "$ip" >> "$BLOCKED_IPS_FILE"
    
    # iptables封禁 - 在链最前面插入，阻止所有端口和协议
    # INPUT: 阻止该IP访问本机任何端口
    iptables -I INPUT 1 -s "$ip" -j DROP 2>/dev/null
    # OUTPUT: 阻止本机向该IP发送任何数据
    iptables -I OUTPUT 1 -d "$ip" -j DROP 2>/dev/null
    # FORWARD: 阻止该IP的转发流量
    iptables -I FORWARD 1 -s "$ip" -j DROP 2>/dev/null
    iptables -I FORWARD 1 -d "$ip" -j DROP 2>/dev/null
    
    # 写入日志
    write_block_log "封禁" "用户 ${user:0:16}... IP: ${ip} (${reason})"
    
    return 0
}

# 解封单个IP
unblock_ip() {
    local ip="$1"
    
    # 从iptables移除（循环删除确保清理干净）
    while iptables -D INPUT -s "$ip" -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -d "$ip" -j DROP 2>/dev/null; do :; done
    while iptables -D FORWARD -s "$ip" -j DROP 2>/dev/null; do :; done
    while iptables -D FORWARD -d "$ip" -j DROP 2>/dev/null; do :; done
    
    # 从文件移除
    if [ -f "$BLOCKED_IPS_FILE" ]; then
        sed -i "/^${ip}$/d" "$BLOCKED_IPS_FILE"
    fi
}

# 清除所有封禁（保留日志记录）
clear_all_blocks() {
    local ip_count=0
    local user_count=0
    
    if [ -f "$BLOCKED_IPS_FILE" ]; then
        ip_count=$(wc -l < "$BLOCKED_IPS_FILE" 2>/dev/null || echo 0)
    fi
    if [ -f "$BLOCKED_USERS_FILE" ]; then
        user_count=$(wc -l < "$BLOCKED_USERS_FILE" 2>/dev/null || echo 0)
    fi
    
    # 从iptables移除所有规则
    if [ -f "$BLOCKED_IPS_FILE" ] && [ -s "$BLOCKED_IPS_FILE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && unblock_ip "$ip"
        done < "$BLOCKED_IPS_FILE"
    fi
    
    # 清空文件
    > "$BLOCKED_IPS_FILE"
    > "$BLOCKED_USERS_FILE"
    
    # 保存iptables
    save_iptables
    
    # 写入日志（保留历史记录，不删除block.log）
    write_block_log "清除" "管理员手动清除所有封禁 (解封${ip_count}个IP，涉及${user_count}个用户)"
}

# 保存iptables规则
save_iptables() {
    case $OS in
        centos)
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/sysconfig/iptables 2>/dev/null
            fi
            ;;
        debian)
            if command -v iptables-save &>/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
            fi
            ;;
    esac
}

# 恢复已封禁的IP（服务启动时调用）
restore_blocked_ips() {
    if [ -f "$BLOCKED_IPS_FILE" ] && [ -s "$BLOCKED_IPS_FILE" ]; then
        local restored_count=0
        while IFS= read -r ip; do
            if [ -n "$ip" ]; then
                # 检查规则是否已存在，避免重复添加
                if ! iptables -C INPUT -s "$ip" -j DROP 2>/dev/null; then
                    iptables -I INPUT 1 -s "$ip" -j DROP 2>/dev/null
                fi
                if ! iptables -C OUTPUT -d "$ip" -j DROP 2>/dev/null; then
                    iptables -I OUTPUT 1 -d "$ip" -j DROP 2>/dev/null
                fi
                if ! iptables -C FORWARD -s "$ip" -j DROP 2>/dev/null; then
                    iptables -I FORWARD 1 -s "$ip" -j DROP 2>/dev/null
                fi
                if ! iptables -C FORWARD -d "$ip" -j DROP 2>/dev/null; then
                    iptables -I FORWARD 1 -d "$ip" -j DROP 2>/dev/null
                fi
                restored_count=$((restored_count + 1))
            fi
        done < "$BLOCKED_IPS_FILE"
        save_iptables
        if [ $restored_count -gt 0 ]; then
            write_block_log "启动" "恢复已封禁IP: ${restored_count}个"
        fi
    fi
}

#=============================================================================
# 核心监控逻辑
#=============================================================================

# 检查并封禁
check_and_block() {
    # 防重入锁
    if [ -f "$LOCK_FILE" ]; then
        local lock_time=$(cat "$LOCK_FILE" 2>/dev/null)
        local now=$(date +%s)
        # 如果锁超过5分钟，强制释放
        if [ -n "$lock_time" ] && [ $((now - lock_time)) -lt 300 ]; then
            return 0
        fi
    fi
    echo "$(date +%s)" > "$LOCK_FILE"
    
    # 加载最新配置
    load_config
    
    local interval_minutes=$((CHECK_INTERVAL))
    local recent_logs=$(get_recent_logs "$interval_minutes")
    
    if [ -z "$recent_logs" ]; then
        rm -f "$LOCK_FILE"
        return 0
    fi
    
    # 提取包含用户信息的行
    local user_lines=$(extract_user_lines "$recent_logs")
    
    if [ -z "$user_lines" ]; then
        rm -f "$LOCK_FILE"
        return 0
    fi
    
    # 提取所有用户
    local users=$(extract_users "$user_lines")
    local blocked_count=0
    
    for user in $users; do
        # 提取该用户的所有IP
        local ips=$(extract_user_ips "$user_lines" "$user")
        local ip_count=$(echo "$ips" | grep -c '.')
        
        if [ "$ip_count" -ge "$IP_THRESHOLD" ]; then
            # 触发封禁
            local first_ip=""
            local blocked_ips=""
            
            for ip in $ips; do
                [ -z "$first_ip" ] && first_ip="$ip"
                block_ip "$ip" "$user" "${CHECK_INTERVAL}分钟内使用${ip_count}个IP，阈值${IP_THRESHOLD}"
                local ret=$?
                if [ $ret -eq 0 ]; then
                    blocked_ips="$blocked_ips $ip"
                fi
            done
            
            # 记录封禁用户
            if ! grep -q "^${user}$" "$BLOCKED_USERS_FILE" 2>/dev/null; then
                echo "$user" >> "$BLOCKED_USERS_FILE"
            fi
            
            if [ -n "$blocked_ips" ]; then
                blocked_count=$((blocked_count + 1))
            fi
        fi
    done
    
    # 保存iptables规则
    if [ -s "$BLOCKED_IPS_FILE" ]; then
        save_iptables
    fi
    
    rm -f "$LOCK_FILE"
}

#=============================================================================
# 定时任务管理
#=============================================================================

create_cron() {
    local interval_minutes="${1:-$CHECK_INTERVAL}"
    local cron_file="/etc/cron.d/${SCRIPT_NAME}"
    
    # 移除旧任务
    rm -f "$cron_file"
    
    # 计算cron表达式
    if [ "$interval_minutes" -gt 60 ]; then
        local hours=$((interval_minutes / 60))
        echo "0 */${hours} * * * root /bin/bash ${SCRIPT_PATH} monitor >> /var/log/${SCRIPT_NAME}.log 2>&1" > "$cron_file"
    elif [ "$interval_minutes" -eq 60 ]; then
        echo "0 * * * * root /bin/bash ${SCRIPT_PATH} monitor >> /var/log/${SCRIPT_NAME}.log 2>&1" > "$cron_file"
    else
        echo "*/${interval_minutes} * * * * root /bin/bash ${SCRIPT_PATH} monitor >> /var/log/${SCRIPT_NAME}.log 2>&1" > "$cron_file"
    fi
    
    # 重启cron
    case $OS in
        centos) systemctl restart crond 2>/dev/null ;;
        debian) systemctl restart cron 2>/dev/null ;;
    esac
}

remove_cron() {
    rm -f "/etc/cron.d/${SCRIPT_NAME}"
    case $OS in
        centos) systemctl restart crond 2>/dev/null ;;
        debian) systemctl restart cron 2>/dev/null ;;
    esac
}

#=============================================================================
# systemd服务管理
#=============================================================================

create_service() {
    cat > "$SERVICE_FILE" << 'SERVICEEOF'
[Unit]
Description=IP Blocker Monitoring Service
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash SCRIPT_PATH_PLACEHOLDER restore
ExecStart=/bin/bash SCRIPT_PATH_PLACEHOLDER monitor-daemon
Restart=always
RestartSec=30
User=root
Group=root

[Install]
WantedBy=multi-user.target
SERVICEEOF

    # 替换占位符
    sed -i "s|SCRIPT_PATH_PLACEHOLDER|${SCRIPT_PATH}|g" "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" 2>/dev/null
}

# 守护进程模式（systemd使用）
monitor_daemon() {
    load_config
    restore_blocked_ips
    
    write_block_log "启动" "监控服务启动 (IP阈值: ${IP_THRESHOLD}个IP/${CHECK_INTERVAL}分钟，检查间隔: ${CHECK_INTERVAL}分钟)"
    
    while true; do
        if [ -f "$MONITOR_STATUS_FILE" ]; then
            local status=$(cat "$MONITOR_STATUS_FILE")
            if [ "$status" = "enabled" ]; then
                check_and_block
            fi
        fi
        sleep $((CHECK_INTERVAL * 60))
    done
}

#=============================================================================
# 菜单显示函数
#=============================================================================

# 主状态显示
show_status() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}         IP封杀脚本状态${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    load_config
    
    # 监控状态
    local status="未配置"
    if [ -f "$MONITOR_STATUS_FILE" ]; then
        status=$(cat "$MONITOR_STATUS_FILE")
    fi
    
    case $status in
        enabled)
            echo -e "${GREEN}监控状态: 运行中 ✓${NC}"
            echo -e "${CYAN}运行时长: $(get_uptime)${NC}"
            ;;
        disabled)
            echo -e "${RED}监控状态: 已暂停 ✗${NC}"
            ;;
        *)
            echo -e "${YELLOW}监控状态: 未配置${NC}"
            ;;
    esac
    
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${CYAN}系统类型: ${OS^}${NC}"
    echo -e "${PURPLE}IP阈值: ${IP_THRESHOLD} 个IP/${CHECK_INTERVAL}分钟${NC}"
    echo -e "${RED}封禁策略: 永久封禁，阻止所有端口${NC}"
    
    # 封禁统计
    local user_count=0
    local ip_count=0
    [ -f "$BLOCKED_USERS_FILE" ] && user_count=$(wc -l < "$BLOCKED_USERS_FILE" 2>/dev/null || echo 0)
    [ -f "$BLOCKED_IPS_FILE" ] && ip_count=$(wc -l < "$BLOCKED_IPS_FILE" 2>/dev/null || echo 0)
    
    echo -e "${YELLOW}封禁用户: ${user_count} 个${NC}"
    echo -e "${RED}封禁IP: ${ip_count} 个${NC}"
    echo -e "${WHITE}总封禁次数: $(get_total_blocks) 次${NC}"
    
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${CYAN}日志路径: ${LOG_FILE}${NC}"
    echo -e "${CYAN}封禁日志: ${BLOCK_LOG_FILE}${NC}"
    
    # 日志文件状态
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        echo -e "${GREEN}日志大小: ${log_size}${NC}"
    else
        echo -e "${RED}警告: 日志文件不存在${NC}"
    fi
    
    echo -e "${BLUE}========================================${NC}"
}

# 菜单1: 部署脚本
menu_deploy() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}         部署 IP封杀脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    # 检查是否已部署
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}检测到已有部署，将重新部署（保留现有封禁规则）${NC}"
        echo ""
    fi
    
    # 环境检测
    echo -e "${CYAN}[环境检测]${NC}"
    
    # 系统检测
    echo -ne "系统支持: "
    case $OS in
        centos|debian) echo -e "${GREEN}✓ ${OS^}${NC}" ;;
        *) echo -e "${RED}✗ 不支持${NC}"; return ;;
    esac
    
    # iptables检测
    echo -ne "iptables: "
    if command -v iptables &>/dev/null; then
        echo -e "${GREEN}✓ 已安装${NC}"
    else
        echo -e "${RED}✗ 未安装${NC}"
    fi
    
    # 日志文件检测
    echo -ne "日志文件: "
    if [ -f "$LOG_FILE" ]; then
        local size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        echo -e "${GREEN}✓ 存在 (${size})${NC}"
    else
        echo -e "${YELLOW}⚠ 不存在，请确认路径${NC}"
    fi
    
    # 定时任务检测
    echo -ne "定时任务: "
    if [ -f "/etc/cron.d/${SCRIPT_NAME}" ]; then
        echo -e "${GREEN}✓ 已配置${NC}"
    else
        echo -e "${YELLOW}⚠ 未配置${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}请设置初始参数:${NC}"
    
    # IP阈值
    local input_threshold
    read -p "IP阈值 [默认: ${DEFAULT_IP_THRESHOLD}]: " input_threshold
    if [[ "$input_threshold" =~ ^[2-9]$|^10$ ]]; then
        IP_THRESHOLD=$input_threshold
    else
        [ -z "$IP_THRESHOLD" ] && IP_THRESHOLD=$DEFAULT_IP_THRESHOLD
        echo -e "${YELLOW}使用当前值: ${IP_THRESHOLD}${NC}"
    fi
    
    # 检查间隔
    local input_interval
    read -p "检查间隔(分钟) [默认: ${DEFAULT_CHECK_INTERVAL}]: " input_interval
    if [[ "$input_interval" =~ ^[1-9][0-9]*$ ]] && [ "$input_interval" -le 1440 ]; then
        CHECK_INTERVAL=$input_interval
    else
        [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL
        echo -e "${YELLOW}使用当前值: ${CHECK_INTERVAL}${NC}"
    fi
    
    echo ""
    echo -e "${RED}封禁策略: 永久封禁，阻止该IP访问本机所有端口${NC}"
    echo ""
    read -p "是否立即部署? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${YELLOW}取消部署${NC}"
        read -p "按回车键继续..."
        return
    fi
    
    # 执行部署
    echo ""
    echo -e "${YELLOW}正在部署...${NC}"
    
    install_dependencies
    init_files
    save_config
    create_service
    create_cron "$CHECK_INTERVAL"
    
    # 恢复已有封禁
    restore_blocked_ips
    
    # 启动服务
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}.service" 2>/dev/null
    
    echo "enabled" > "$MONITOR_STATUS_FILE"
    
    write_block_log "部署" "脚本部署完成 (IP阈值: ${IP_THRESHOLD}，检查间隔: ${CHECK_INTERVAL}分钟，封禁策略: 永久)"
    write_block_log "启动" "监控服务启动 (IP阈值: ${IP_THRESHOLD}个IP/${CHECK_INTERVAL}分钟，检查间隔: ${CHECK_INTERVAL}分钟)"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ 依赖已安装${NC}"
    echo -e "${GREEN}✓ 配置文件已创建${NC}"
    echo -e "${GREEN}✓ 系统服务已设置（开机自启）${NC}"
    echo -e "${GREEN}✓ 定时任务已创建${NC}"
    echo -e "${GREEN}✓ IP阈值: ${IP_THRESHOLD} 个IP/${CHECK_INTERVAL}分钟${NC}"
    echo -e "${RED}✓ 封禁策略: 永久封禁，阻止所有端口${NC}"
    echo ""
    read -p "按回车键继续..."
}

# 菜单2: 监控开关设置
menu_monitor_control() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}         监控开关设置${NC}"
        echo -e "${BLUE}========================================${NC}"
        
        local status="未知"
        [ -f "$MONITOR_STATUS_FILE" ] && status=$(cat "$MONITOR_STATUS_FILE")
        
        echo -e "${YELLOW}当前状态: ${status}${NC}"
        if [ "$status" = "enabled" ]; then
            echo -e "${CYAN}运行时长: $(get_uptime)${NC}"
        fi
        echo -e "${RED}注意: 暂停/恢复操作不会影响已封禁的IP${NC}"
        echo -e "${BLUE}----------------------------------------${NC}"
        echo ""
        
        echo -e "${RED}1) 暂停监控${NC}"
        echo -e "${GREEN}2) 恢复监控${NC}"
        echo -e "${CYAN}3) 手动触发一次检查${NC}"
        echo -e "${PURPLE}4) 修改检查间隔 [当前: ${CHECK_INTERVAL}分钟]${NC}"
        echo -e "${WHITE}0) 返回主菜单${NC}"
        echo ""
        read -p "请选择: " choice
        
        case $choice in
            1)
                # 暂停监控
                echo ""
                read -p "请输入暂停时长(小时, 支持小数如0.5): " hours
                if [[ "$hours" =~ ^[0-9]+\.?[0-9]*$ ]] && [ -n "$hours" ] && [ "$(echo "$hours > 0" | bc 2>/dev/null || echo 1)" = "1" ]; then
                    # 计算分钟数
                    local minutes=$(awk "BEGIN {printf \"%.0f\", $hours * 60}")
                    
                    echo "disabled" > "$MONITOR_STATUS_FILE"
                    remove_cron
                    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null
                    
                    # 计算恢复时间
                    local resume_ts=$(date -d "+${minutes} minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
                    
                    write_block_log "暂停" "监控手动暂停 (暂停时长: ${hours}小时，计划恢复: ${resume_ts})，已封禁IP不受影响"
                    
                    # 设置恢复定时任务
                    local resume_minute=$(date -d "+${minutes} minutes" '+%M' 2>/dev/null)
                    local resume_hour=$(date -d "+${minutes} minutes" '+%H' 2>/dev/null)
                    local resume_day=$(date -d "+${minutes} minutes" '+%d' 2>/dev/null)
                    local resume_month=$(date -d "+${minutes} minutes" '+%m' 2>/dev/null)
                    
                    (crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} enable-monitor"; echo "${resume_minute} ${resume_hour} ${resume_day} ${resume_month} * /bin/bash ${SCRIPT_PATH} enable-monitor") | crontab -
                    
                    echo -e "${GREEN}监控已暂停（已封禁IP保持不变）${NC}"
                    echo -e "${YELLOW}计划恢复时间: ${resume_ts}${NC}"
                else
                    echo -e "${RED}输入无效${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            2)
                # 恢复监控
                echo "enabled" > "$MONITOR_STATUS_FILE"
                create_cron "$CHECK_INTERVAL"
                systemctl restart "${SERVICE_NAME}.service" 2>/dev/null
                
                # 清除恢复定时任务
                crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} enable-monitor" | crontab - 2>/dev/null
                
                write_block_log "恢复" "监控手动恢复运行，已封禁IP保持不变"
                
                echo -e "${GREEN}监控已恢复（已封禁IP保持不变）${NC}"
                read -p "按回车键继续..."
                ;;
            3)
                # 手动触发检查
                echo ""
                echo -e "${YELLOW}正在执行手动检查...${NC}"
                
                local before_count=$(get_total_blocks)
                check_and_block
                local after_count=$(get_total_blocks)
                local new_blocks=$((after_count - before_count))
                
                if [ "$new_blocks" -gt 0 ]; then
                    write_block_log "手动检查" "手动触发检查完成 (新封禁${new_blocks}个用户)"
                    echo -e "${RED}检查完成，新封禁了 ${new_blocks} 个用户${NC}"
                else
                    write_block_log "手动检查" "手动触发检查完成 (无异常用户)"
                    echo -e "${GREEN}检查完成，未发现异常用户${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            4)
                # 修改检查间隔
                echo ""
                read -p "请输入新的检查间隔(分钟, 1-1440): " new_interval
                if [[ "$new_interval" =~ ^[1-9][0-9]*$ ]] && [ "$new_interval" -le 1440 ]; then
                    local old_interval=$CHECK_INTERVAL
                    CHECK_INTERVAL=$new_interval
                    save_config
                    create_cron "$CHECK_INTERVAL"
                    
                    write_block_log "配置" "检查间隔修改: ${old_interval}分钟 → ${CHECK_INTERVAL}分钟"
                    
                    echo -e "${GREEN}检查间隔已更新为: ${CHECK_INTERVAL}分钟${NC}"
                else
                    echo -e "${RED}请输入1-1440之间的数字${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

# 菜单3: 修改IP封禁阈值
menu_modify_threshold() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       修改IP封禁阈值${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${YELLOW}当前阈值: ${IP_THRESHOLD} 个IP/${CHECK_INTERVAL}分钟${NC}"
    echo -e "${CYAN}说明: 当用户在检查间隔内使用的IP数量≥阈值时，封禁该用户所有IP${NC}"
    echo -e "${RED}封禁策略: 永久封禁，阻止所有端口${NC}"
    echo ""
    echo -e "${YELLOW}参考值:${NC}"
    echo -e "  2 - 严格模式 (快速响应，可能误封)"
    echo -e "  3 - 标准模式 (推荐)"
    echo -e "  5 - 宽松模式 (减少误封，响应较慢)"
    echo ""
    
    read -p "请输入新阈值 [2-10，当前: ${IP_THRESHOLD}]: " new_threshold
    
    if [[ "$new_threshold" =~ ^[2-9]$|^10$ ]]; then
        local old_threshold=$IP_THRESHOLD
        IP_THRESHOLD=$new_threshold
        save_config
        
        write_block_log "配置" "IP阈值修改: ${old_threshold} → ${IP_THRESHOLD}"
        
        echo -e "${GREEN}IP阈值已更新为: ${IP_THRESHOLD}${NC}"
        echo -e "${YELLOW}新阈值将在下次检查时生效${NC}"
    else
        echo -e "${RED}无效输入！请输入2-10之间的数字${NC}"
    fi
    
    read -p "按回车键继续..."
}

# 菜单4: 封禁列表管理
menu_blocked_list() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       封禁列表管理${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    local user_count=0
    local ip_count=0
    [ -f "$BLOCKED_USERS_FILE" ] && user_count=$(wc -l < "$BLOCKED_USERS_FILE" 2>/dev/null || echo 0)
    [ -f "$BLOCKED_IPS_FILE" ] && ip_count=$(wc -l < "$BLOCKED_IPS_FILE" 2>/dev/null || echo 0)
    
    echo -e "${YELLOW}封禁用户: ${user_count} 个${NC}"
    echo -e "${RED}封禁IP: ${ip_count} 个${NC}"
    echo -e "${RED}封禁策略: 永久封禁，阻止所有端口${NC}"
    echo -e "${CYAN}----------------------------------------${NC}"
    
    if [ "$user_count" -gt 0 ] && [ -f "$BLOCKED_USERS_FILE" ]; then
        while IFS= read -r user; do
            [ -z "$user" ] && continue
            echo -e "${PURPLE}用户: ${user:0:24}...${NC}"
            
            # 从封禁日志中查找该用户被封禁的IP
            local user_ips=$(grep "用户 ${user:0:16}" "$BLOCK_LOG_FILE" 2>/dev/null | grep '\[封禁\]' | grep -oP 'IP: \K[0-9.]+' | sort -u)
            
            if [ -n "$user_ips" ]; then
                local count=$(echo "$user_ips" | wc -l)
                echo -e "${YELLOW}  封禁IP数量: ${count}个${NC}"
                echo "$user_ips" | while read ip; do
                    # 验证该IP确实在封禁列表中
                    if grep -q "^${ip}$" "$BLOCKED_IPS_FILE" 2>/dev/null; then
                        echo -e "  ${RED}● ${ip} [已封禁]${NC}"
                    fi
                done
            fi
            echo ""
        done < "$BLOCKED_USERS_FILE"
    else
        echo -e "${GREEN}当前没有封禁记录${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}----------------------------------------${NC}"
    echo ""
    echo -e "${RED}1) 一键清除所有封禁 (保留日志记录)${NC}"
    echo -e "${WHITE}0) 返回主菜单${NC}"
    echo ""
    read -p "请选择: " choice
    
    case $choice in
        1)
            echo ""
            read -p "确认清除所有封禁？已封禁IP将恢复访问权限，日志记录保留 (y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                clear_all_blocks
                echo -e "${GREEN}所有封禁已清除，IP恢复访问，日志已保留${NC}"
            else
                echo -e "${YELLOW}已取消${NC}"
            fi
            read -p "按回车键继续..."
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            read -p "按回车键继续..."
            ;;
    esac
}

# 菜单5: 查看封禁日志
menu_view_logs() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}         封禁日志${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo -e "${CYAN}日志文件: ${BLOCK_LOG_FILE}${NC}"
        
        local log_count=0
        [ -f "$BLOCK_LOG_FILE" ] && log_count=$(wc -l < "$BLOCK_LOG_FILE" 2>/dev/null || echo 0)
        echo -e "${YELLOW}总记录数: ${log_count}条${NC}"
        echo ""
        
        echo -e "${GREEN}1) 查看全部日志${NC}"
        echo -e "${CYAN}2) 搜索指定用户/IP${NC}"
        echo -e "${WHITE}0) 返回主菜单${NC}"
        echo ""
        read -p "请选择: " choice
        
        case $choice in
            1)
                # 查看全部日志
                if [ -f "$BLOCK_LOG_FILE" ] && [ -s "$BLOCK_LOG_FILE" ]; then
                    local total_lines=$(wc -l < "$BLOCK_LOG_FILE")
                    local page_size=20
                    local total_pages=$(( (total_lines + page_size - 1) / page_size ))
                    local current_page=1
                    
                    while true; do
                        clear
                        echo -e "${BLUE}========================================${NC}"
                        echo -e "${BLUE}         全部封禁日志${NC}"
                        echo -e "${BLUE}========================================${NC}"
                        
                        if [ "$total_pages" -gt 1 ]; then
                            echo -e "${CYAN}第${current_page}/${total_pages}页 (共${total_lines}条记录)${NC}"
                        else
                            echo -e "${CYAN}共${total_lines}条记录${NC}"
                        fi
                        echo -e "${BLUE}----------------------------------------${NC}"
                        
                        local start_line=$(( (current_page - 1) * page_size + 1 ))
                        local end_line=$(( current_page * page_size ))
                        
                        sed -n "${start_line},${end_line}p" "$BLOCK_LOG_FILE" | while IFS= read -r line; do
                            if [[ "$line" == *"[封禁]"* ]]; then
                                echo -e "${RED}${line}${NC}"
                            elif [[ "$line" == *"[解封]"* ]]; then
                                echo -e "${GREEN}${line}${NC}"
                            elif [[ "$line" == *"[清除]"* ]]; then
                                echo -e "${YELLOW}${line}${NC}"
                            elif [[ "$line" == *"[启动]"* ]] || [[ "$line" == *"[恢复]"* ]]; then
                                echo -e "${GREEN}${line}${NC}"
                            elif [[ "$line" == *"[暂停]"* ]]; then
                                echo -e "${YELLOW}${line}${NC}"
                            elif [[ "$line" == *"[配置]"* ]] || [[ "$line" == *"[部署]"* ]]; then
                                echo -e "${CYAN}${line}${NC}"
                            elif [[ "$line" == *"[手动检查]"* ]]; then
                                echo -e "${WHITE}${line}${NC}"
                            else
                                echo -e "${WHITE}${line}${NC}"
                            fi
                        done
                        
                        echo ""
                        if [ "$total_pages" -le 1 ]; then
                            echo -e "${WHITE}输入q退出${NC}"
                            read -p "" nav
                            [ "$nav" = "q" ] || [ "$nav" = "Q" ] && break
                        else
                            echo -e "${WHITE}n: 下一页  p: 上一页  q: 退出${NC}"
                            read -p "请选择: " nav
                            case $nav in
                                n|N) [ "$current_page" -lt "$total_pages" ] && current_page=$((current_page + 1)) ;;
                                p|P) [ "$current_page" -gt 1 ] && current_page=$((current_page - 1)) ;;
                                q|Q) break ;;
                                *) break ;;
                            esac
                        fi
                    done
                else
                    echo -e "${YELLOW}暂无日志记录${NC}"
                    read -p "按回车键继续..."
                fi
                ;;
            2)
                # 搜索
                clear
                echo -e "${BLUE}========================================${NC}"
                echo -e "${BLUE}       搜索封禁日志${NC}"
                echo -e "${BLUE}========================================${NC}"
                echo ""
                echo -e "${CYAN}请输入搜索关键词 (用户hash或IP地址):${NC}"
                echo -e "${YELLOW}例如: d33357d002251f3e 或 218.82.22.174${NC}"
                echo ""
                read -p "关键词: " keyword
                
                if [ -n "$keyword" ]; then
                    echo ""
                    echo -e "${CYAN}搜索结果:${NC}"
                    echo -e "${CYAN}----------------------------------------${NC}"
                    
                    local results=""
                    if [ -f "$BLOCK_LOG_FILE" ]; then
                        results=$(grep -i "$keyword" "$BLOCK_LOG_FILE" 2>/dev/null)
                    fi
                    
                    if [ -n "$results" ]; then
                        echo "$results" | while IFS= read -r line; do
                            if [[ "$line" == *"[封禁]"* ]]; then
                                echo -e "${RED}${line}${NC}"
                            elif [[ "$line" == *"[解封]"* ]]; then
                                echo -e "${GREEN}${line}${NC}"
                            elif [[ "$line" == *"[清除]"* ]]; then
                                echo -e "${YELLOW}${line}${NC}"
                            else
                                echo -e "${WHITE}${line}${NC}"
                            fi
                        done
                        local result_count=$(echo "$results" | wc -l)
                        echo -e "${CYAN}----------------------------------------${NC}"
                        echo -e "${GREEN}找到 ${result_count} 条记录${NC}"
                    else
                        echo -e "${YELLOW}未找到匹配记录${NC}"
                    fi
                else
                    echo -e "${RED}请输入搜索关键词${NC}"
                fi
                echo ""
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

#=============================================================================
# 主菜单
#=============================================================================

main_menu() {
    load_config
    
    while true; do
        show_status
        echo -e "${BLUE}           操作菜单${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo -e "${GREEN}1) 部署/重新部署脚本${NC}"
        echo -e "${YELLOW}2) 监控开关设置${NC}"
        echo -e "${PURPLE}3) 修改IP封禁阈值 [当前: ${IP_THRESHOLD}]${NC}"
        echo -e "${CYAN}4) 封禁列表管理${NC}"
        echo -e "${WHITE}5) 查看封禁日志${NC}"
        echo -e "${RED}6) 退出${NC}"
        echo -e "${BLUE}========================================${NC}"
        read -p "请选择操作 [1-6]: " choice
        
        case $choice in
            1) menu_deploy ;;
            2) menu_monitor_control ;;
            3) menu_modify_threshold ;;
            4) menu_blocked_list ;;
            5) menu_view_logs ;;
            6)
                echo -e "${GREEN}感谢使用！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重试${NC}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

#=============================================================================
# 命令行入口
#=============================================================================

case "$1" in
    monitor)
        # cron调用入口
        load_config
        if [ -f "$MONITOR_STATUS_FILE" ]; then
            status=$(cat "$MONITOR_STATUS_FILE")
            if [ "$status" = "enabled" ]; then
                check_and_block
            fi
        fi
        ;;
    monitor-daemon)
        # systemd守护进程入口
        monitor_daemon
        ;;
    restore)
        # systemd启动前恢复封禁
        load_config
        restore_blocked_ips
        ;;
    enable-monitor)
        # 自动恢复监控
        load_config
        echo "enabled" > "$MONITOR_STATUS_FILE"
        create_cron "$CHECK_INTERVAL"
        systemctl restart "${SERVICE_NAME}.service" 2>/dev/null
        write_block_log "恢复" "监控自动恢复运行，已封禁IP保持不变"
        # 清除恢复定时任务
        crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} enable-monitor" | crontab - 2>/dev/null
        ;;
    *)
        check_root
        detect_os
        main_menu
        ;;
esac