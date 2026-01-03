#!/bin/bash

HOSTS_FILE="/etc/hosts"
TAG_BEGIN="# AI_BLOCK_BEGIN"
TAG_END="# AI_BLOCK_END"

BLOCK_DOMAINS=(
"127.0.0.1 chatgpt.com"
"127.0.0.1 www.chatgpt.com"
"127.0.0.1 gemini.google.com"
)

function enable_block() {
    if grep -q "$TAG_BEGIN" "$HOSTS_FILE"; then
        echo "已开启屏蔽，无需重复操作"
        return
    fi

    echo "$TAG_BEGIN" >> "$HOSTS_FILE"
    for domain in "${BLOCK_DOMAINS[@]}"; do
        echo "$domain" >> "$HOSTS_FILE"
    done
    echo "$TAG_END" >> "$HOSTS_FILE"

    echo "屏蔽已开启"
}

function disable_block() {
    if ! grep -q "$TAG_BEGIN" "$HOSTS_FILE"; then
        echo "当前未开启屏蔽"
        return
    fi

    sed -i "/$TAG_BEGIN/,/$TAG_END/d" "$HOSTS_FILE"
    echo "屏蔽已解除"
}

while true; do
    echo
    echo "====== 域名屏蔽菜单 ======"
    echo "1：开启屏蔽"
    echo "2：解除屏蔽"
    echo "3：退出"
    read -p "请选择 [1-3]：" choice

    case "$choice" in
        1)
            enable_block
            ;;
        2)
            disable_block
            ;;
        3)
            exit 0
            ;;
        *)
            echo "无效选择"
            ;;
    esac
done
