#!/bin/bash

# ==========================================
# 增强版：多接口 IP 检测 + mKCP 直播加速
# ==========================================

[[ $EUID -ne 0 ]] && echo "错误：请使用 root 用户运行此脚本" && exit 1

# 1. 自动安装必要依赖
echo "正在安装基础组件..."
if [[ -f /usr/bin/apt ]]; then
    apt-get update && apt-get install -y curl qrencode jq
elif [[ -f /usr/bin/yum ]]; then
    yum install -y curl qrencode jq
fi

# 2. 增强型 IP 获取逻辑 (多接口备份)
get_ip() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org)
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 https://ifconfig.me)
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 https://ipinfo.io/ip)
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 https://api.myip.com | jq -r .ip)
    echo "$ip"
}

IP=$(get_ip)

if [[ -z "$IP" ]]; then
    echo "--------------------------------------------------"
    echo "⚠️ 自动获取公网 IP 失败！"
    read -p "请手动输入你的 VPS 公网 IP: " IP
    echo "--------------------------------------------------"
fi

# 3. 参数配置
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=443
CONF_PATH="/usr/local/etc/v2ray/config.json"

# 4. 安装 V2Ray
echo "正在安装 V2Ray 内核..."
curl -Ls https://raw.githubusercontent.com/v2fly/fscript/master/install.sh | bash

# 5. 写入直播专用配置 (mKCP + 防 DNS 泄露)
cat > $CONF_PATH <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
    "streamSettings": {
      "network": "mkcp",
      "kcpSettings": {
        "uplinkCapacity": 100,
        "downlinkCapacity": 100,
        "congestion": true,
        "header": { "type": "wechat-video" }
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIP" } },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "dns": { "servers": [ "8.8.8.8", "1.1.1.1", "localhost" ] },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" },
      { "type": "field", "port": 53, "outboundTag": "direct" }
    ]
  }
}
EOF

# 6. 重启服务
systemctl enable v2ray
systemctl restart v2ray

# 7. 生成链接
VMESS_JSON=$(cat <<EOF
{
  "v": "2", "ps": "Live_Speed_Up", "add": "$IP", "port": "$PORT", "id": "$UUID",
  "aid": "0", "scy": "auto", "net": "mkcp", "type": "wechat-video", "tls": ""
}
EOF
)
VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

# 8. 输出
clear
echo "--------------------------------------------------"
echo "✅ 安装成功！针对直播推流已完成底层优化。"
echo "--------------------------------------------------"
echo "公网 IP: $IP"
echo "连接端口: $PORT (必须放行 UDP)"
echo "用户 ID: $UUID"
echo "传输网络: mKCP (wechat-video)"
echo "--------------------------------------------------"
echo "🔗 VMess 链接:"
echo "$VMESS_LINK"
echo "--------------------------------------------------"
echo "📱 手机扫码导入:"
echo ""
echo "$VMESS_LINK" | qrencode -t ANSI256
echo "--------------------------------------------------"
echo "⚠️  重要提示："
echo "1. 请务必在云服务器控制台开启 UDP 协议的 $PORT 端口。"
echo "2. 直播前请在客户端开启“流量探测 (Sniffing)”功能以防 DNS 泄露。"
