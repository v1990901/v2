#!/bin/bash
# V2Ray 工业级防封中转脚本 - 强制远端DNS + 灵活UUID版

# 确保退格键和基础环境
stty erase ^?
apt-get update && apt-get install -y curl wget unzip jq qrencode cron

clear
echo -e "\033[35m==================================================\033[0m"
echo -e "\033[35m      V2Ray 工业级防封中转脚本 (防 DNS 泄露)       \033[0m"
echo -e "\033[35m==================================================\033[0m"

# 1. 交互输入
read -e -p "1. 阿里云入口端口 (默认 54321): " ALIYUN_PORT
ALIYUN_PORT=${ALIYUN_PORT:-54321}

read -e -p "2. 美国静态 IP 地址: " USA_IP
read -e -p "3. 落地端口: " USA_PORT
read -e -p "4. SOCKS5 账号: " USA_USER
read -e -p "5. SOCKS5 密码: " USA_PASS

# UUID 逻辑：手动或随机
echo -e "\033[33m提示：直接回车将自动生成随机 UUID\033[0m"
read -e -p "6. 请输入自定义 UUID: " CUSTOM_UUID
if [ -z "$CUSTOM_UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "已生成随机 UUID: $UUID"
else
    UUID=$CUSTOM_UUID
    echo -e "已使用自定义 UUID: $UUID"
fi

# 2. 开启内核优化与 BBR
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf <<SYS
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
SYS
    sysctl -p > /dev/null 2>&1
fi

# 3. 安装核心
mkdir -p /usr/local/etc/v2ray /var/log/v2ray
wget -O /tmp/v2ray.zip https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip
unzip -o /tmp/v2ray.zip -d /usr/local/bin/
chmod +x /usr/local/bin/v2ray

# 4. 生成防封配置 (强制远端解析 + 流量嗅探)
cat <<CONF > /usr/local/etc/v2ray/config.json
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1", "localhost"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [{
    "port": $ALIYUN_PORT,
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
    "streamSettings": { "network": "tcp" },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [
    {
      "tag": "usa_exit",
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": "$USA_IP",
          "port": $USA_PORT,
          "users": [{ "user": "$USA_USER", "pass": "$USA_PASS" }]
        }]
      }
    },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "port": "53", "outboundTag": "usa_exit" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "usa_exit" }
    ]
  }
}
CONF

# 5. 设置 Systemd 服务
cat <<SERV > /etc/systemd/system/v2ray.service
[Unit]
Description=V2Ray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/v2ray run -config /usr/local/etc/v2ray/config.json
Restart=always
[Install]
WantedBy=multi-user.target
SERV

systemctl daemon-reload && systemctl enable v2ray && systemctl restart v2ray

# 6. 生成链接与自适应二维码
MY_IP=$(curl -s http://checkip.amazonaws.com)
VMESS_CONF=$(cat <<VMJSON
{ "v": "2", "ps": "Safe_Relay", "add": "$MY_IP", "port": "$ALIYUN_PORT", "id": "$UUID", "aid": "0", "net": "tcp", "type": "none", "host": "", "path": "", "tls": "" }
VMJSON
)
VMESS_LINK="vmess://$(echo -n "$VMESS_CONF" | base64 -w 0)"

clear
echo -e "\033[32m==================================================\033[0m"
echo -e "✅ 工业级防封配置部署成功"
echo -e "--------------------------------------------------"
echo -e "入口地址: \033[33m$MY_IP : $ALIYUN_PORT\033[0m"
echo -e "用户 ID: \033[33m$UUID\033[0m"
echo -e "防御状态: \033[32mDNS 强制远端解析已开启\033[0m"
echo -e "--------------------------------------------------"
echo -e "节点配置二维码 (自适应终端尺寸):"
echo -e "\033[32m"
echo "$VMESS_LINK" | qrencode -t UTF8
echo -e "\033[0m"
echo -e "--------------------------------------------------"
echo -e "VMess 链接:"
echo -e "\033[36m$VMESS_LINK\033[0m"
echo -e "\033[32m==================================================\033[0m"
