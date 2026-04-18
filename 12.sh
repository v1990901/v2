#!/bin/bash

# ==========================================
# 针对抖音直播优化的 V2Ray 一键脚本
# 特性：mKCP加速、防DNS泄露、自动生成链接
# ==========================================

# 1. 环境准备
[[ $EUID -ne 0 ]] && echo "错误：请使用 root 用户运行此脚本" && exit 1
apt-get update && apt-get install -y curl qrencode jq || yum install -y curl qrencode jq

# 2. 参数定义
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=54321
IP=$(curl -s https://api.ipify.org)
REMARKS="Douyin_Live_Accelerator"
CONF_PATH="/usr/local/etc/v2ray/config.json"

# 3. 安装官方内核
echo "正在安装 V2Ray 内核..."
curl -Ls https://raw.githubusercontent.com/v2fly/fscript/master/install.sh | bash

# 4. 写入针对直播优化的配置
echo "正在配置加速环境..."
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

# 5. 启动服务
systemctl enable v2ray
systemctl restart v2ray

# 6. 生成 VMess 链接 (注意：直播版使用了 mkcp 和 wechat-video 伪装)
VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "$REMARKS",
  "add": "$IP",
  "port": "$PORT",
  "id": "$UUID",
  "aid": "0",
  "scy": "auto",
  "net": "mkcp",
  "type": "wechat-video",
  "host": "",
  "path": "",
  "tls": "",
  "sni": ""
}
EOF
)

VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

# 7. 结果输出
clear
echo "=================================================="
echo "✅ 抖音直播专用加速节点安装完成！"
echo "=================================================="
echo "协议: VMess (mKCP)"
echo "伪装类型: wechat-video (模拟微信视频流，防QoS)"
echo "地址: $IP"
echo "端口: $PORT"
echo "UUID: $UUID"
echo "=================================================="
echo "🔗 VMess 链接 (直接复制到 V2RayN 使用):"
echo "$VMESS_LINK"
echo "=================================================="
echo "📱 手机扫码导入:"
echo ""
echo "$VMESS_LINK" | qrencode -t ANSI256
echo "=================================================="
echo "提示：请确保 VPS 防火墙已放行 UDP 端口 $PORT"
