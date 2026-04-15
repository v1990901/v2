#!/bin/bash

# =================================================================
# 脚本名称：Gemini 矩阵管理 v5.5 (泰国 AIS 原生 IP 优化版)
# 适用环境：Ubuntu 20.04+, Debian 10+
# 功能：VMess + 泰国住宅 IP 链式转发，支持二维码与修改
# =================================================================

# 颜色与路径
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
CONFIG_FILE="/usr/local/etc/v2ray/config.json"

# --- 1. 系统优化与环境初始化 ---
function init_system() {
    echo -e "${YELLOW}正在检查环境与优化网络...${NC}"
    # BBR 加速
    if ! sysctl net.core.default_qdisc | grep -q "fq" ; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi
    # 基础依赖
    apt-get update -y && apt-get install -y jq qrencode curl base64 uuid-runtime
    # 内核安装 (使用 v2fly 官方稳定安装方式)
    if ! command -v v2ray &> /dev/null; then
        echo -e "${YELLOW}正在安装 V2Ray 核心...${NC}"
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fbt-install/master/install.sh)
        systemctl enable v2ray && systemctl start v2ray
    fi
    # 基础配置模版
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p /usr/local/etc/v2ray
        cat > $CONFIG_FILE <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["1.1.1.1", "8.8.8.8", "localhost"] },
  "inbounds": [],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }],
  "routing": { "rules": [] }
}
EOF
    fi
}

# --- 2. 生成二维码与链接 ---
function show_access_info() {
    local port=$1; local uuid=$2; local remarks=$3
    local ip=$(curl -s ifconfig.me)
    # 采用更通用的 VMess 配置格式
    local v_json=$(cat <<EOF
{ "v": "2", "ps": "$remarks", "add": "$ip", "port": "$port", "id": "$uuid", "aid": "0", "net": "ws", "type": "none", "host": "", "path": "/th-relay", "tls": "" }
EOF
)
    local link="vmess://$(echo -n "$v_json" | base64 -w 0)"
    echo -e "\n${GREEN}================ 连接信息 ================${NC}"
    echo -e "${GREEN}备注名称: ${NC}$remarks"
    echo -e "${GREEN}VMess 链接: ${NC}$link"
    echo -e "${GREEN}二维码 (扫码直接导入):${NC}"
    qrencode -t ansiutf8 "$link"
}

# --- 3. 添加新落地 (已预设您提供的泰国IP) ---
function add_relay() {
    echo -e "${GREEN}--- 添加新落地 ---${NC}"
    echo -e "${YELLOW}提示：直接回车可使用您提供的泰国原生 IP 配置${NC}"
    read -p "本地中转端口 (例如 50100): " l_port
    read -p "落地 Host [112.143.3.164]: " r_host
    r_host=${r_host:-"112.143.3.164"}
    read -p "落地 Port [50101]: " r_port
    r_port=${r_port:-50101}
    read -p "落地 User [gbalm123]: " r_user
    r_user=${r_user:-"gbalm123"}
    read -p "落地 Pass [Pud9bikqoz]: " r_pass
    r_pass=${r_pass:-"Pud9bikqoz"}
    read -p "备注名称 (如 TK_Thai_AIS): " remarks
    remarks=${remarks:-"Thai_Relay_$l_port"}

    uuid=$(uuidgen)
    tag="relay_$l_port"

    # 添加 Inbound (采用 WS 协议更稳定)
    jq ".inbounds += [{\"port\": $l_port, \"protocol\": \"vmess\", \"settings\": {\"clients\": [{\"id\": \"$uuid\"}]}, \"tag\": \"in-$tag\", \"streamSettings\": {\"network\": \"ws\", \"wsSettings\": {\"path\": \"/th-relay\"}}}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    # 添加 Outbound (Socks 链式)
    jq ".outbounds += [{\"protocol\": \"socks\", \"settings\": {\"servers\": [{\"address\": \"$r_host\", \"port\": $r_port, \"users\": [{\"user\": \"$r_user\", \"pass\": \"$r_pass\"}]}]}, \"tag\": \"out-$tag\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    # 添加路由规则 (强制对应转发)
    jq ".routing.rules += [{\"type\": \"field\", \"inboundTag\": [\"in-$tag\"], \"outboundTag\": \"out-$tag\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE

    systemctl restart v2ray
    show_access_info "$l_port" "$uuid" "$remarks"
}

# --- 4. 修改现有落地 ---
function edit_relay() {
    echo -e "${YELLOW}--- 修改现有落地 ---${NC}"
    ports=$(jq -r '.inbounds[].port' $CONFIG_FILE)
    if [ -z "$ports" ]; then echo "没有可修改的配置"; return; fi
    echo "当前可用端口: $ports"
    read -p "请输入你想修改的本地端口: " target_port

    if ! jq -e ".inbounds[] | select(.port == $target_port)" $CONFIG_FILE > /dev/null; then
        echo -e "${RED}未找到该端口配置${NC}"; return
    fi

    read -p "新落地 Host: " n_host
    read -p "新落地 Port: " n_port
    read -p "新落地 User: " n_user
    read -p "新落地 Pass: " n_pass

    tag="relay_$target_port"
    [ ! -z "$n_host" ] && jq "(.outbounds[] | select(.tag == \"out-$tag\")).settings.servers[0].address = \"$n_host\"" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    [ ! -z "$n_port" ] && jq "(.outbounds[] | select(.tag == \"out-$tag\")).settings.servers[0].port = $n_port" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    [ ! -z "$n_user" ] && jq "(.outbounds[] | select(.tag == \"out-$tag\")).settings.servers[0].users[0].user = \"$n_user\"" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    [ ! -z "$n_pass" ] && jq "(.outbounds[] | select(.tag == \"out-$tag\")).settings.servers[0].users[0].pass = \"$n_pass\"" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE

    systemctl restart v2ray
    u_id=$(jq -r ".inbounds[] | select(.port == $target_port) | .settings.clients[0].id" $CONFIG_FILE)
    show_access_info "$target_port" "$u_id" "Edited_$target_port"
}

# --- 5. 主菜单 ---
init_system
while true; do
    echo -e "\n${YELLOW}Gemini 矩阵管理 v5.5 (泰国 AIS 原生 IP 优化版)${NC}"
    echo "1) 添加新落地 (内置您提供的泰国静态住宅 IP)"
    echo "2) 修改现有落地 (Edit)"
    echo "3) 查看配置列表"
    echo "4) 重置/清空所有配置"
    echo "5) 退出"
    read -p "请选择 [1-5]: " opt
    case $opt in
        1) add_relay ;;
        2) edit_relay ;;
        3) jq -r '.inbounds[] | "本地监听端口: \(.port) \t 路由标签: \(.tag)"' $CONFIG_FILE ;;
        4) rm -f $CONFIG_FILE && init_system && systemctl restart v2ray && echo "已重置" ;;
        5) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
