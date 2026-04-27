#!/bin/bash
# ================================================================
#  Xray 落地IP 管理系统 v3.0 - 外贸/跨境电商专用
#  优化项：BBR加速 | TCP内核调优 | VLESS+Reality | 连接复用
#          DNS防泄漏 | 并发安装 | IP缓存 | 全交互菜单
# ================================================================

set -uo pipefail

# ── 颜色 ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; PURPLE='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── 路径常量 ─────────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
LANDING_DIR="/etc/xray/landings"
LOG_DIR="/var/log/xray"
SCRIPT_SELF="/usr/local/bin/xray-manager"
CACHE_FILE="/tmp/.xray_mgr_cache"
VERSION="3.0"

# ── 辅助函数 ─────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
step()    { echo -e "${CYAN}[→]${NC} $*"; }
title()   { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
divider() { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }
pause()   { read -rp "$(echo -e "${DIM}  按回车继续...${NC}")"; }
yesno()   { read -rp "$(echo -e "${YELLOW}$* (y/N): ${NC}")" _yn; [[ "$_yn" =~ ^[Yy]$ ]]; }

check_root() {
    [ "$(id -u)" -eq 0 ] || { error "请以 root 用户运行"; exit 1; }
}

# ── 公网IP（带60s缓存，避免每次刷菜单都请求）──────────────────
get_public_ip() {
    local now cache_time cached_ip
    now=$(date +%s)
    if [ -f "$CACHE_FILE" ]; then
        cache_time=$(awk -F= '/TIME/{print $2}' "$CACHE_FILE" 2>/dev/null || echo 0)
        cached_ip=$(awk  -F= '/^IP/{print $2}'  "$CACHE_FILE" 2>/dev/null || echo "")
        if [ $((now - cache_time)) -lt 60 ] && [ -n "$cached_ip" ]; then
            echo "$cached_ip"; return
        fi
    fi
    local ip
    ip=$(curl -s --max-time 4 https://api.ipify.org   2>/dev/null \
      || curl -s --max-time 4 https://ifconfig.me     2>/dev/null \
      || curl -s --max-time 4 https://icanhazip.com   2>/dev/null \
      || echo "未知")
    printf "TIME=%s\nIP=%s\n" "$now" "$ip" > "$CACHE_FILE"
    echo "$ip"
}

gen_uuid() { cat /proc/sys/kernel/random/uuid; }

# ── 【优化①】BBR + 内核TCP调优 ──────────────────────────────────
tune_kernel() {
    title "内核网络加速（BBR + TCP调优）"

    modprobe tcp_bbr 2>/dev/null && info "BBR 模块已加载" || warn "BBR 模块加载失败"

    cat > /etc/sysctl.d/99-xray-boost.conf << 'SYSCTL'
# ── 拥塞控制（BBR）──
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区（适合香港→海外高延迟链路）──
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.core.rmem_default           = 1048576
net.core.wmem_default           = 1048576
net.ipv4.tcp_rmem               = 4096 1048576 67108864
net.ipv4.tcp_wmem               = 4096 1048576 67108864
net.ipv4.udp_rmem_min           = 8192
net.ipv4.udp_wmem_min           = 8192

# ── 连接加速 ──
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save    = 1
net.ipv4.tcp_ecn                = 1
net.ipv4.tcp_frto               = 2
net.ipv4.tcp_mtu_probing        = 1

# ── 连接队列与复用 ──
net.core.somaxconn              = 32768
net.ipv4.tcp_max_syn_backlog    = 32768
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.ip_local_port_range    = 10000 65535

# ── Keepalive ──
net.ipv4.tcp_keepalive_time     = 60
net.ipv4.tcp_keepalive_intvl    = 10
net.ipv4.tcp_keepalive_probes   = 3
net.ipv4.tcp_max_tw_buckets     = 262144

# ── 转发（落地服务器必须开）──
net.ipv4.ip_forward             = 1
SYSCTL

    sysctl -p /etc/sysctl.d/99-xray-boost.conf -q && info "sysctl 参数已应用" || warn "部分参数应用失败"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [ "$cc" = "bbr" ] && info "BBR 已成功启用 ✓" || warn "当前拥塞控制: $cc（BBR 未生效，可能内核<4.9）"
    pause
}

# ── 安装 Xray 核心 ────────────────────────────────────────────────
install_xray() {
    title "安装 Xray 核心"
    if [ -f "$XRAY_BIN" ]; then
        local ver; ver=$("$XRAY_BIN" version 2>/dev/null | head -1 || echo "已安装")
        warn "Xray 已安装: $ver"
        yesno "是否升级到最新版？" && \
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        return
    fi
    step "安装依赖..."
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq curl wget unzip jq uuid-runtime net-tools iproute2 2>/dev/null
    step "安装 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    mkdir -p "$LANDING_DIR" "$LOG_DIR"
    info "Xray 安装完成: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

# ── 【优化②】重建主服务器配置（VLESS Reality / VMess WS 双支持）──
rebuild_main_config() {
    mkdir -p "$LANDING_DIR" "$LOG_DIR"
    local inbounds='[]'

    for conf in "$LANDING_DIR"/*.conf 2>/dev/null; do
        [ -f "$conf" ] || continue
        unset LANDING_IP IP_NAME INBOUND_PORT UUID STATUS PROTO PRIVATE_KEY PUBLIC_KEY SHORT_ID
        # shellcheck disable=SC1090
        source "$conf"
        [ "${STATUS:-}" = "active" ] || continue

        local block
        if [ "${PROTO:-vmess}" = "vless" ]; then
            # VLESS + Reality（速度快，抗检测）
            block=$(jq -n \
                --argjson port  "$INBOUND_PORT" \
                --arg     uuid  "$UUID" \
                --arg     pk    "${PRIVATE_KEY:-}" \
                --arg     sid   "${SHORT_ID:-}" \
                --arg     tag   "in_${INBOUND_PORT}" \
                '{
                    port: $port, listen: "0.0.0.0",
                    protocol: "vless",
                    settings: {
                        clients: [{ id: $uuid, flow: "xtls-rprx-vision" }],
                        decryption: "none"
                    },
                    streamSettings: {
                        network: "tcp", security: "reality",
                        realitySettings: {
                            show: false,
                            dest: "www.microsoft.com:443",
                            xver: 0,
                            serverNames: ["www.microsoft.com","microsoft.com"],
                            privateKey: $pk,
                            shortIds: [$sid]
                        }
                    },
                    sniffing: { enabled: true, destOverride: ["http","tls","quic"] },
                    tag: $tag
                }')
        else
            # VMess + WebSocket（兼容性好）
            block=$(jq -n \
                --argjson port "$INBOUND_PORT" \
                --arg     uuid "$UUID" \
                --arg     path "/ws_${INBOUND_PORT}" \
                --arg     tag  "in_${INBOUND_PORT}" \
                '{
                    port: $port, listen: "0.0.0.0",
                    protocol: "vmess",
                    settings: { clients: [{ id: $uuid, alterId: 0 }] },
                    streamSettings: {
                        network: "ws",
                        wsSettings: { path: $path },
                        sockopt: { tcpFastOpen: true }
                    },
                    sniffing: { enabled: true, destOverride: ["http","tls"] },
                    tag: $tag
                }')
        fi
        inbounds=$(echo "$inbounds" | jq ". + [$block]")
    done

    # 写入完整配置（含 DoH DNS防泄漏、路由、policy调优）
    cat > "$XRAY_CONFIG" << JSONEOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/access.log",
    "error":  "${LOG_DIR}/error.log"
  },
  "dns": {
    "hosts": {
      "dns.google":     "8.8.8.8",
      "dns.cloudflare": "1.1.1.1",
      "geosite:category-ads-all": "127.0.0.1"
    },
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "domains": ["geosite:geolocation-!cn","geosite:tld-!cn"],
        "expectIPs": ["geoip:!cn"],
        "queryStrategy": "UseIPv4"
      },
      {
        "address": "https://8.8.8.8/dns-query",
        "domains": ["geosite:geolocation-!cn"]
      },
      {
        "address": "223.5.5.5",
        "domains": ["geosite:cn"],
        "expectIPs": ["geoip:cn"]
      },
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableFallbackIfMatch": true
  },
  "inbounds": $inbounds,
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": { "sockopt": { "tcpFastOpen": true } },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": { "response": { "type": "http" } },
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 1,
        "downlinkOnly": 1,
        "bufferSize": 512
      }
    }
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "domainMatcher": "hybrid",
    "rules": [
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:private","127.0.0.1/8"],  "outboundTag": "block" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
JSONEOF

    systemctl restart xray 2>/dev/null \
        && info "主配置已更新，Xray 重启成功" \
        || warn "Xray 重启失败 → journalctl -u xray -n 20"
}

# ── 添加落地IP ────────────────────────────────────────────────────
add_landing() {
    title "添加落地IP"
    divider

    read -rp "  落地IP地址（住宅静态IP）: " LANDING_IP
    [[ -z "$LANDING_IP" ]] && { error "IP不能为空"; pause; return; }

    if [ -f "$LANDING_DIR/${LANDING_IP}.conf" ]; then
        yesno "  该IP已存在，是否覆盖？" || return
    fi

    read -rp "  备注名称（如 美国住宅01）: " IP_NAME
    read -rp "  入站监听端口（如 10001，每个IP唯一）: " INBOUND_PORT

    if ! [[ "$INBOUND_PORT" =~ ^[0-9]+$ ]] || \
       [ "$INBOUND_PORT" -lt 1024 ] || [ "$INBOUND_PORT" -gt 65535 ]; then
        error "端口必须在 1024-65535 之间"; pause; return
    fi

    # 端口冲突检查
    for c in "$LANDING_DIR"/*.conf 2>/dev/null; do
        [ -f "$c" ] || continue
        [ "$c" = "$LANDING_DIR/${LANDING_IP}.conf" ] && continue
        local used_port
        used_port=$(grep "^INBOUND_PORT=" "$c" 2>/dev/null | cut -d= -f2)
        if [ "$used_port" = "$INBOUND_PORT" ]; then
            error "端口 $INBOUND_PORT 已被 $(grep '^IP_NAME=' "$c" | cut -d= -f2) 使用"
            pause; return
        fi
    done

    # 协议选择
    echo ""
    echo -e "  选择传输协议:"
    echo -e "  ${GREEN}1${NC} VMess + WebSocket  （兼容性最好，推荐新手）"
    echo -e "  ${GREEN}2${NC} VLESS + Reality     （速度更快，抗检测更强 ★推荐）"
    read -rp "  请选择 [1/2，默认1]: " PROTO_SEL
    PROTO_SEL=${PROTO_SEL:-1}

    local UUID PROTO PRIVATE_KEY PUBLIC_KEY SHORT_ID
    UUID=$(gen_uuid)

    if [ "$PROTO_SEL" = "2" ]; then
        PROTO="vless"
        step "生成 Reality 密钥对..."
        local keypair
        keypair=$("$XRAY_BIN" x25519 2>/dev/null)
        PRIVATE_KEY=$(echo "$keypair" | grep "Private" | awk '{print $3}')
        PUBLIC_KEY=$(echo  "$keypair" | grep "Public"  | awk '{print $3}')
        SHORT_ID=$(openssl rand -hex 4)
        info "Reality 密钥对生成完成"
    else
        PROTO="vmess"
        PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
    fi

    local HK_IP
    HK_IP=$(get_public_ip)

    cat > "$LANDING_DIR/${LANDING_IP}.conf" << EOF
LANDING_IP=${LANDING_IP}
IP_NAME=${IP_NAME}
INBOUND_PORT=${INBOUND_PORT}
UUID=${UUID}
PROTO=${PROTO}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
STATUS=active
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    rebuild_main_config

    # 输出落地服务器安装命令
    divider
    echo -e "${BOLD}${GREEN}  ✓ 落地IP已添加！请在落地服务器（${LANDING_IP}）上执行以下命令：${NC}"
    divider

    # 公共前置部分（BBR加速+安装Xray）
    local COMMON_INSTALL
    COMMON_INSTALL=$(cat << CMDINST
apt-get update -qq && apt-get install -y -qq curl iproute2

# 内核加速
cat > /etc/sysctl.d/99-boost.conf << 'SYS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_forward=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
SYS
modprobe tcp_bbr 2>/dev/null
sysctl -p /etc/sysctl.d/99-boost.conf -q

bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
CMDINST
)

    if [ "$PROTO" = "vless" ]; then
        cat << REMOTE
#!/bin/bash
# ===== 落地服务器安装（VLESS + Reality）=====
${COMMON_INSTALL}

cat > /usr/local/etc/xray/config.json << 'LANDCONF'
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [
      { "address": "https://1.1.1.1/dns-query", "queryStrategy": "UseIPv4" },
      "8.8.8.8"
    ]
  },
  "inbounds": [{
    "port": 10800,
    "protocol": "dokodemo-door",
    "settings": { "network": "tcp,udp", "followRedirect": true },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] },
    "tag": "transparent"
  }],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${HK_IP}",
          "port": ${INBOUND_PORT},
          "users": [{ "id": "${UUID}", "flow": "xtls-rprx-vision", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "www.microsoft.com",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "spiderX": "/"
        },
        "sockopt": { "tcpFastOpen": true }
      },
      "tag": "proxy"
    },
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "UseIPv4",
    "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" }]
  }
}
LANDCONF

systemctl enable xray && systemctl restart xray
echo "===== 落地服务器（VLESS+Reality）配置完成！====="
REMOTE
    else
        cat << REMOTE
#!/bin/bash
# ===== 落地服务器安装（VMess + WebSocket）=====
${COMMON_INSTALL}

cat > /usr/local/etc/xray/config.json << 'LANDCONF'
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [
      { "address": "https://1.1.1.1/dns-query", "queryStrategy": "UseIPv4" },
      "8.8.8.8"
    ]
  },
  "inbounds": [{
    "port": 10800,
    "protocol": "dokodemo-door",
    "settings": { "network": "tcp,udp", "followRedirect": true },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] },
    "tag": "transparent"
  }],
  "outbounds": [
    {
      "protocol": "vmess",
      "settings": {
        "vnext": [{
          "address": "${HK_IP}",
          "port": ${INBOUND_PORT},
          "users": [{ "id": "${UUID}", "alterId": 0, "security": "auto" }]
        }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/ws_${INBOUND_PORT}" },
        "sockopt": { "tcpFastOpen": true }
      },
      "mux": { "enabled": true, "concurrency": 8 },
      "tag": "proxy"
    },
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "UseIPv4",
    "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" }]
  }
}
LANDCONF

systemctl enable xray && systemctl restart xray
echo "===== 落地服务器（VMess+WS）配置完成！====="
REMOTE
    fi

    divider
    echo -e "  ${CYAN}主服务器IP:${NC}  $HK_IP"
    echo -e "  ${CYAN}落地IP:${NC}      $LANDING_IP  ($IP_NAME)"
    echo -e "  ${CYAN}端口:${NC}        $INBOUND_PORT"
    echo -e "  ${CYAN}协议:${NC}        $PROTO"
    [ "$PROTO" = "vless" ] && echo -e "  ${CYAN}公钥:${NC}        $PUBLIC_KEY"
    divider
    pause
}

# ── 删除落地IP ────────────────────────────────────────────────────
remove_landing() {
    title "删除落地IP"
    list_landings_table
    echo ""
    read -rp "  输入要删除的落地IP（q取消）: " DEL_IP
    [[ "$DEL_IP" = "q" || -z "$DEL_IP" ]] && return

    local conf="$LANDING_DIR/${DEL_IP}.conf"
    [ -f "$conf" ] || { error "未找到该IP"; pause; return; }
    # shellcheck disable=SC1090
    source "$conf"
    yesno "  确认删除 ${IP_NAME}（${DEL_IP}）？" || { pause; return; }
    rm -f "$conf"
    rebuild_main_config
    info "已删除 $DEL_IP"
    pause
}

# ── 启用/禁用落地IP ───────────────────────────────────────────────
toggle_landing() {
    title "启用 / 禁用落地IP"
    list_landings_table
    echo ""
    read -rp "  输入落地IP地址（q取消）: " SEL_IP
    [[ "$SEL_IP" = "q" || -z "$SEL_IP" ]] && return

    local conf="$LANDING_DIR/${SEL_IP}.conf"
    [ -f "$conf" ] || { error "未找到该IP"; pause; return; }
    # shellcheck disable=SC1090
    source "$conf"
    if [ "$STATUS" = "active" ]; then
        sed -i 's/^STATUS=.*/STATUS=disabled/' "$conf"
        warn "$IP_NAME ($SEL_IP) 已禁用"
    else
        sed -i 's/^STATUS=.*/STATUS=active/' "$conf"
        info "$IP_NAME ($SEL_IP) 已启用"
    fi
    rebuild_main_config
    pause
}

# ── 落地IP列表 ────────────────────────────────────────────────────
list_landings_table() {
    title "落地IP 列表"
    divider
    printf "  ${BOLD}%-4s %-18s %-16s %-7s %-9s %-8s${NC}\n" \
           "#" "名称" "IP" "端口" "协议" "状态"
    divider
    local i=1 found=0
    for conf in "$LANDING_DIR"/*.conf 2>/dev/null; do
        [ -f "$conf" ] || continue
        found=1
        unset LANDING_IP IP_NAME INBOUND_PORT UUID STATUS PROTO
        # shellcheck disable=SC1090
        source "$conf"
        local sc=$GREEN
        [ "${STATUS:-}" = "disabled" ] && sc=$RED
        local plabel="${PROTO:-vmess}"
        [ "$plabel" = "vless" ] && plabel="${CYAN}reality${NC}" || plabel="${GREEN}ws    ${NC}"
        printf "  %-4s %-18s %-16s %-7s " "$i" "${IP_NAME:-N/A}" "$LANDING_IP" "$INBOUND_PORT"
        echo -ne "$plabel  "
        echo -e "${sc}${STATUS:-?}${NC}"
        i=$((i+1))
    done
    [ "$found" -eq 0 ] && echo -e "  ${YELLOW}暂无落地IP，请先添加${NC}"
    divider
}

# ── 生成客户端配置 ────────────────────────────────────────────────
gen_client_config() {
    title "生成客户端配置"
    list_landings_table
    echo ""
    read -rp "  输入落地IP地址（q取消）: " SEL_IP
    [[ "$SEL_IP" = "q" || -z "$SEL_IP" ]] && return

    local conf="$LANDING_DIR/${SEL_IP}.conf"
    [ -f "$conf" ] || { error "未找到该IP"; pause; return; }
    unset LANDING_IP IP_NAME INBOUND_PORT UUID STATUS PROTO PUBLIC_KEY SHORT_ID
    # shellcheck disable=SC1090
    source "$conf"

    local HK_IP; HK_IP=$(get_public_ip)
    local out_file="/root/client_${LANDING_IP}.txt"
    divider

    if [ "${PROTO:-vmess}" = "vless" ]; then
        local link="vless://${UUID}@${HK_IP}:${INBOUND_PORT}"
        link+="?encryption=none&flow=xtls-rprx-vision&security=reality"
        link+="&sni=www.microsoft.com&fp=chrome"
        link+="&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${IP_NAME}"

        echo -e "${BOLD}${GREEN}  VLESS + Reality 客户端配置${NC}"
        divider
        echo -e "  ${CYAN}导入链接:${NC}"; echo "  $link"; echo ""
        printf "  %-12s %s\n" "地址:"    "$HK_IP"
        printf "  %-12s %s\n" "端口:"    "$INBOUND_PORT"
        printf "  %-12s %s\n" "UUID:"    "$UUID"
        printf "  %-12s %s\n" "Flow:"    "xtls-rprx-vision"
        printf "  %-12s %s\n" "传输:"    "TCP + Reality"
        printf "  %-12s %s\n" "SNI:"     "www.microsoft.com"
        printf "  %-12s %s\n" "指纹:"    "chrome"
        printf "  %-12s %s\n" "公钥:"    "$PUBLIC_KEY"
        printf "  %-12s %s\n" "ShortID:" "$SHORT_ID"
        printf "  %-12s %s\n" "落地IP:"  "$LANDING_IP ($IP_NAME)"
        { echo "落地IP: $LANDING_IP ($IP_NAME)"; echo "VLESS Link: $link"; } > "$out_file"
    else
        local vmess_json vmess_link
        vmess_json=$(jq -nc \
            --arg  v    "2"    --arg  ps  "$IP_NAME"  --arg  add "$HK_IP" \
            --argjson port "$INBOUND_PORT"             --arg  id  "$UUID" \
            --argjson aid  0   --arg  net "ws"         --arg  type "none" \
            --arg  host ""     --arg  path "/ws_${INBOUND_PORT}" --arg tls "" \
            '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:$aid,net:$net,type:$type,host:$host,path:$path,tls:$tls}')
        vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w 0)"

        echo -e "${BOLD}${GREEN}  VMess + WebSocket 客户端配置${NC}"
        divider
        echo -e "  ${CYAN}导入链接:${NC}"; echo "  $vmess_link"; echo ""
        printf "  %-12s %s\n" "地址:"    "$HK_IP"
        printf "  %-12s %s\n" "端口:"    "$INBOUND_PORT"
        printf "  %-12s %s\n" "UUID:"    "$UUID"
        printf "  %-12s %s\n" "AlterID:" "0"
        printf "  %-12s %s\n" "传输:"    "WebSocket"
        printf "  %-12s %s\n" "路径:"    "/ws_${INBOUND_PORT}"
        printf "  %-12s %s\n" "落地IP:"  "$LANDING_IP ($IP_NAME)"
        { echo "落地IP: $LANDING_IP ($IP_NAME)"; echo "VMess Link: $vmess_link"; } > "$out_file"
    fi

    divider
    info "配置已保存到 $out_file"
    pause
}

# ── 防火墙 ────────────────────────────────────────────────────────
setup_firewall() {
    title "配置防火墙（UFW）"
    command -v ufw &>/dev/null || apt-get install -y -qq ufw
    ufw --force reset 2>/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "SSH"

    for conf in "$LANDING_DIR"/*.conf 2>/dev/null; do
        [ -f "$conf" ] || continue
        unset IP_NAME INBOUND_PORT LANDING_IP
        # shellcheck disable=SC1090
        source "$conf"
        # 只允许对应落地IP连接对应端口，提升安全性
        ufw allow from "$LANDING_IP" to any port "$INBOUND_PORT" proto tcp \
            comment "Xray-${IP_NAME}"
    done

    ufw --force enable 2>/dev/null
    info "防火墙配置完成"
    ufw status verbose
    pause
}

# ── 服务状态 ──────────────────────────────────────────────────────
show_status() {
    title "Xray 服务状态"
    systemctl status xray --no-pager -l 2>/dev/null || error "Xray 未运行"
    divider
    echo -e "  ${CYAN}监听端口:${NC}"
    ss -tlnp 2>/dev/null | grep xray || echo "  （无法获取）"
    divider
    echo -e "  ${CYAN}BBR 状态:${NC}"
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    qd=$(sysctl -n net.core.default_qdisc          2>/dev/null || echo "未知")
    echo -e "  拥塞控制: ${GREEN}${cc}${NC}   队列: ${GREEN}${qd}${NC}"
    divider
    echo -e "  ${CYAN}最近错误日志（后10行）:${NC}"
    tail -10 "$LOG_DIR/error.log" 2>/dev/null || echo "  日志为空"
    pause
}

# ── 测速 ──────────────────────────────────────────────────────────
speed_test() {
    title "网络测速"
    step "使用 curl 测试到 Cloudflare 的下载速度..."
    curl -o /dev/null -s --max-time 15 \
        -w "  下载速度: %{speed_download} bytes/s\n  耗时: %{time_total}s\n" \
        "https://speed.cloudflare.com/__down?bytes=10000000" || warn "测速失败"
    echo ""
    step "延迟测试（ping 1.1.1.1）..."
    ping -c 5 1.1.1.1 2>/dev/null | tail -2 || warn "ping 失败"
    pause
}

# ── 首次完整安装 ──────────────────────────────────────────────────
full_install() {
    title "首次完整安装"
    divider
    echo -e "  ${YELLOW}此操作将：${NC}"
    echo "    1. 安装 Xray 核心（最新版）"
    echo "    2. 开启 BBR + TCP 内核调优"
    echo "    3. 生成基础配置（含 DoH DNS 防泄漏）"
    echo "    4. 配置 UFW 防火墙"
    echo "    5. 安装管理脚本到系统路径（xray-manager）"
    divider
    yesno "  确认安装？" || return

    install_xray
    mkdir -p "$LANDING_DIR" "$LOG_DIR"
    tune_kernel
    rebuild_main_config

    if [ "$0" != "$SCRIPT_SELF" ]; then
        cp "$0" "$SCRIPT_SELF" && chmod +x "$SCRIPT_SELF"
        info "管理脚本已安装 → 以后直接运行 xray-manager"
    fi

    setup_firewall
    divider
    info "安装完成！版本: $("$XRAY_BIN" version 2>/dev/null | head -1)"
    pause
}

# ── 主菜单 ────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        local HK_IP cnt active_cnt xray_status
        HK_IP=$(get_public_ip)
        cnt=$(ls "$LANDING_DIR"/*.conf 2>/dev/null | wc -l)
        active_cnt=$(grep -rl "^STATUS=active" "$LANDING_DIR" 2>/dev/null | wc -l)
        systemctl is-active xray &>/dev/null \
            && xray_status="${GREEN}运行中${NC}" \
            || xray_status="${RED}已停止${NC}"
        local cc
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")

        echo -e "${BOLD}${PURPLE}"
        cat << 'BANNER'
  ╔════════════════════════════════════════════════════╗
  ║    Xray 外贸落地IP 管理系统  v3.0                 ║
  ║    BBR加速 · VLESS Reality · 多IP · DNS防泄漏     ║
  ╚════════════════════════════════════════════════════╝
BANNER
        echo -e "${NC}"
        printf "  本机IP: ${CYAN}%-18s${NC}  Xray: %b\n" "$HK_IP" "$xray_status"
        printf "  落地IP: ${GREEN}%s${NC} 启用 / %s 总计   BBR: ${GREEN}%s${NC}\n" \
               "$active_cnt" "$cnt" "$cc"
        divider
        echo -e "  ${BOLD}── 安装与加速 ────────────────────────────${NC}"
        echo -e "  ${GREEN}1.${NC}  首次安装 / 初始化"
        echo -e "  ${GREEN}2.${NC}  开启 BBR 加速（单独执行）"
        echo -e "  ${BOLD}── 落地IP 管理 ───────────────────────────${NC}"
        echo -e "  ${GREEN}3.${NC}  添加落地IP"
        echo -e "  ${GREEN}4.${NC}  删除落地IP"
        echo -e "  ${GREEN}5.${NC}  启用 / 禁用落地IP"
        echo -e "  ${GREEN}6.${NC}  查看落地IP列表"
        echo -e "  ${BOLD}── 配置与维护 ────────────────────────────${NC}"
        echo -e "  ${GREEN}7.${NC}  生成客户端配置"
        echo -e "  ${GREEN}8.${NC}  配置防火墙"
        echo -e "  ${GREEN}9.${NC}  查看服务状态 / 日志"
        echo -e "  ${GREEN}10.${NC} 网络测速"
        echo -e "  ${GREEN}11.${NC} 重启 Xray"
        echo -e "  ${GREEN}12.${NC} 重建主配置（修复用）"
        divider
        echo -e "  ${RED}0.${NC}  退出"
        divider
        read -rp "$(echo -e "  ${BOLD}请选择 [0-12]: ${NC}")" choice

        case "$choice" in
            1)  full_install ;;
            2)  tune_kernel ;;
            3)  add_landing ;;
            4)  remove_landing ;;
            5)  toggle_landing ;;
            6)  list_landings_table; pause ;;
            7)  gen_client_config ;;
            8)  setup_firewall ;;
            9)  show_status ;;
            10) speed_test ;;
            11) systemctl restart xray && info "Xray 已重启" || error "重启失败"; sleep 1 ;;
            12) rebuild_main_config; pause ;;
            0)  echo -e "${GREEN}再见！${NC}"; rm -f "$CACHE_FILE"; exit 0 ;;
            *)  warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────────────
check_root
main_menu
