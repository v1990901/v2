#!/bin/bash
# ================================================================
#  Xray 落地IP 管理系统 v3.2 - 外贸/跨境电商深度定制版
#  更新：支持二维码输出 | 增强型 DNS 防泄漏 | Reality 指纹模拟
#  适配：Ubuntu 20.04+, Debian 10+
# ================================================================

set -u

# ── 颜色定义 ──────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   PURPLE='\033[0;35m'
BOLD='\033[1m';    DIM='\033[2m';        NC='\033[0m'

# ── 路径常量 ──────────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
LANDING_DIR="/etc/xray/landings"
LOG_DIR="/var/log/xray"
SCRIPT_SELF="/usr/local/bin/xray-manager"
CACHE_FILE="/tmp/.xray_mgr_cache"

# ── 辅助函数 ──────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
step()    { echo -e "${CYAN}[→]${NC} $*"; }
title()   { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
divider() { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }
pause()   { read -rp "$(echo -e "${DIM}  按回车继续...${NC}")"; }
yesno()   { local _yn; read -rp "$(echo -e "${YELLOW}$* (y/N): ${NC}")" _yn; [[ "$_yn" =~ ^[Yy]$ ]]; }

check_root() {
    [ "$(id -u)" -eq 0 ] || { error "请以 root 用户运行"; exit 1; }
}

each_conf() {
    local fn="$1"
    local files
    files=$(find "$LANDING_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | sort)
    [ -z "$files" ] && return 0
    while IFS= read -r conf; do
        [ -f "$conf" ] || continue
        "$fn" "$conf"
    done <<< "$files"
}

get_public_ip() {
    local now=$(date +%s)
    if [ -f "$CACHE_FILE" ]; then
        local cache_time=$(grep '^TIME=' "$CACHE_FILE" | cut -d= -f2)
        local cached_ip=$(grep '^IP=' "$CACHE_FILE" | cut -d= -f2)
        if [ $(( now - cache_time )) -lt 60 ] && [ -n "$cached_ip" ]; then
            echo "$cached_ip"; return
        fi
    fi
    local ip=$(curl -s --max-time 4 https://api.ipify.org || echo "未知")
    printf 'TIME=%s\nIP=%s\n' "$now" "$ip" > "$CACHE_FILE"
    echo "$ip"
}

gen_uuid() { cat /proc/sys/kernel/random/uuid; }

load_conf() {
    unset LANDING_IP IP_NAME INBOUND_PORT UUID STATUS \
          PROTO PRIVATE_KEY PUBLIC_KEY SHORT_ID CREATED
    source "$1"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 【1】内核 BBR 调优
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
tune_kernel() {
    title "内核加速（BBR + TCP 调优）"
    modprobe tcp_bbr 2>/dev/null
    cat > /etc/sysctl.d/99-xray-boost.conf << 'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_forward = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-xray-boost.conf -q
    info "BBR 加速已应用 ✓"
    pause
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 【2】安装 Xray 及 依赖
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_xray() {
    title "安装/升级系统组件"
    step "正在安装必要依赖 (jq, qrencode, curl)..."
    apt-get update -qq && apt-get install -y -qq curl jq qrencode uuid-runtime ufw
    
    step "正在安装 Xray 核心..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    mkdir -p "$LANDING_DIR" "$LOG_DIR"
    info "组件安装完成 ✓"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 【3】重建 Xray 主配置（含 DoH）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
rebuild_main_config() {
    local inbounds='[]'
    _build_inbound() {
        load_conf "$1"
        [ "${STATUS:-}" = "active" ] || return 0
        local block
        if [ "${PROTO:-}" = "vless" ]; then
            block=$(jq -n --argjson port "$INBOUND_PORT" --arg uuid "$UUID" --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg tag "in_$INBOUND_PORT" \
                '{port:$port, protocol:"vless", settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none"},
                  streamSettings:{network:"tcp", security:"reality", realitySettings:{show:false, dest:"www.microsoft.com:443", xver:0, serverNames:["www.microsoft.com"], privateKey:$pk, shortIds:[$sid]}},
                  sniffing:{enabled:true, destOverride:["http","tls","quic"]}, tag:$tag}')
        else
            block=$(jq -n --argjson port "$INBOUND_PORT" --arg uuid "$UUID" --arg path "/ws_$INBOUND_PORT" --arg tag "in_$INBOUND_PORT" \
                '{port:$port, protocol:"vmess", settings:{clients:[{id:$uuid}]}, streamSettings:{network:"ws", wsSettings:{path:$path}},
                  sniffing:{enabled:true, destOverride:["http","tls"]}, tag:$tag}')
        fi
        inbounds=$(echo "$inbounds" | jq ". + [$block]")
    }
    each_conf _build_inbound

    # 写入 JSON 配置文件
    cat > "$XRAY_CONFIG" << EOF
{
    "log": {"loglevel": "warning", "access": "$LOG_DIR/access.log", "error": "$LOG_DIR/error.log"},
    "dns": {
        "servers": ["https://1.1.1.1/dns-query", "8.8.8.8"],
        "queryStrategy": "UseIPv4"
    },
    "inbounds": $inbounds,
    "outbounds": [
        {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
            {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}
        ]
    }
}
EOF
    systemctl restart xray && info "主配置已生效 ✓"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 【4】生成二维码与导入链接
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
gen_client_config() {
    title "客户端导出"
    list_landings_table
    read -rp "  输入落地IP地址: " SEL_IP
    local conf="$LANDING_DIR/${SEL_IP}.conf"
    [ -f "$conf" ] || { error "找不到配置"; return; }
    load_conf "$conf"
    local HK_IP=$(get_public_ip)
    local link=""

    divider
    if [ "$PROTO" = "vless" ]; then
        link="vless://${UUID}@${HK_IP}:${INBOUND_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${IP_NAME}"
        info "VLESS + Reality 链接已生成"
    else
        local v_json=$(jq -nc --arg ps "$IP_NAME" --arg add "$HK_IP" --argjson port "$INBOUND_PORT" --arg id "$UUID" --arg path "/ws_$INBOUND_PORT" \
            '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"ws",type:"none",host:"",path:$path,tls:""}')
        link="vmess://$(printf '%s' "$v_json" | base64 -w 0)"
        info "VMess + WS 链接已生成"
    fi

    echo -e "\n${YELLOW}导入链接:${NC}\n${CYAN}${link}${NC}\n"
    echo -e "${YELLOW}手机扫码导入:${NC}"
    echo "$link" | qrencode -t ANSI256
    divider
    pause
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 【5】其他管理功能
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
add_landing() {
    title "添加落地IP"
    read -rp "  落地IP地址 (泰国/海外): " LANDING_IP
    read -rp "  备注名称: " IP_NAME
    read -rp "  入站端口 (1024-65535): " INBOUND_PORT
    
    echo -e "  选择协议: ${GREEN}1. VLESS+Reality(推荐)${NC}  2. VMess+WS"
    read -rp "  请选择 [1/2]: " P_SEL
    if [ "$P_SEL" = "2" ]; then PROTO="vmess"; else PROTO="vless"; fi

    UUID=$(gen_uuid)
    PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
    if [ "$PROTO" = "vless" ]; then
        local kp=$($XRAY_BIN x25519)
        PRIVATE_KEY=$(echo "$kp" | awk '/Private/{print $3}')
        PUBLIC_KEY=$(echo "$kp" | awk '/Public/{print $3}')
        SHORT_ID=$(openssl rand -hex 4)
    fi

    cat > "$LANDING_DIR/${LANDING_IP}.conf" << EOF
LANDING_IP=$LANDING_IP
IP_NAME=$IP_NAME
INBOUND_PORT=$INBOUND_PORT
UUID=$UUID
PROTO=$PROTO
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
STATUS=active
EOF
    rebuild_main_config
    info "落地IP $IP_NAME 已保存"
    pause
}

list_landings_table() {
    divider
    printf "  ${BOLD}%-18s %-16s %-7s %-8s${NC}\n" "名称" "IP" "端口" "状态"
    divider
    each_conf _row() {
        load_conf "$1"
        local color="${GREEN}"; [ "$STATUS" != "active" ] && color="${RED}"
        printf "  %-18s %-16s %-7s ${color}%-8s${NC}\n" "$IP_NAME" "$LANDING_IP" "$INBOUND_PORT" "$STATUS"
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 主菜单
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main_menu() {
    while true; do
        clear
        echo -e "${PURPLE}${BOLD}  Xray 外贸多IP管理系统 v3.2${NC}"
        echo -e "  本机IP: ${CYAN}$(get_public_ip)${NC}"
        divider
        echo -e "  ${GREEN}1.${NC} 首次全自动安装"
        echo -e "  ${GREEN}2.${NC} 添加落地IP配置"
        echo -e "  ${GREEN}3.${NC} 生成导入二维码/链接"
        echo -e "  ${GREEN}4.${NC} 查看落地IP列表"
        echo -e "  ${GREEN}5.${NC} 删除落地IP"
        echo -e "  ${GREEN}6.${NC} 开启 BBR 加速"
        echo -e "  ${GREEN}7.${NC} Xray 服务状态/日志"
        echo -e "  ${RED}0.${NC} 退出"
        divider
        read -rp "  请选择: " opt
        case $opt in
            1) install_xray; tune_kernel; rebuild_main_config; pause ;;
            2) add_landing ;;
            3) gen_client_config ;;
            4) list_landings_table; pause ;;
            5) read -rp "输入要删除的IP: " dip; rm -f "$LANDING_DIR/${dip}.conf"; rebuild_main_config; pause ;;
            6) tune_kernel ;;
            7) title "服务状态"; systemctl status xray --no-pager; tail -n 10 "$LOG_DIR/error.log"; pause ;;
            0) exit 0 ;;
        esac
    done
}

check_root
main_menu
