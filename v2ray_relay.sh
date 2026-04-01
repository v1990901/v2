#!/bin/bash

 #1. 环境准备
apt-get update && apt-get install -y curl wget unzip jq qrencode cron

clear
echo -e "\033[36m==================================================\033[0m"
echo -e "\033[36m      V2Ray 中转美国静态 IP 交互脚本 (支持退格)      \033[0m"
echo -e "\033[36m==================================================\033[0m"

# 使用 read -e 支持 Backspace 退格修改
read -e -p "1. 阿里云入口端口 (默认 54321): " ALIYUN_PORT
ALIYUN_PORT=${ALIYUN_PORT:-54321}

read -e -p "2. 美国静态 IP 地址: " USA_IP
read -e -p "3. 美国静态 IP 端口: " USA_PORT
read -e -p "4. SOCKS5 账号: " USA_USER
read -e -p "5. SOCKS5 密码: " USA_PASS

# 开启内核 BBR 加速
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

# 安装 V2Ray 核心 (自动获取最新版)
mkdir -p /usr/local/etc/v2ray /var/log/v2ray
DOWNLOAD_URL="https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip"
wget -O /tmp/v2ray.zip $DOWNLOAD_URL
unzip -o /tmp/v2ray.zip -d /usr/local/bin/
chmod +x /usr/local/bin/v2ray

#写入配置 (含 UDP 优化)
UUID=$(cat /proc/sys/kernel/random/uuid)
cat <<CONF > /usr/local/etc/v2ray/config.json
{
  "log": { "loglevel": "warning" },
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
    "rules": [{ "type": "field", "network": "tcp,udp", "outboundTag": "usa_exit" }]
  }
}
CONF

# 配置并启动服务
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

# 生成链接与二维码
MY_IP=$(curl -s http://checkip.amazonaws.com)
VMESS_CONF=$(cat <<VMJSON
{ "v": "2", "ps": "Ali_US_Relay", "add": "$MY_IP", "port": "$ALIYUN_PORT", "id": "$UUID", "aid": "0", "net": "tcp", "type": "none", "host": "", "path": "", "tls": "" }
VMJSON
)
VMESS_LINK="vmess://$(echo -n "$VMESS_CONF" | base64 -w 0)"

clear
echo -e "\033[32m==================================================\033[0m"
echo -e "\033[32m            ✅ 配置完成 - 请保存以下信息             \033[0m"
echo -e "\033[32m==================================================\033[0m"
echo -e "入口地址: \033[33m$MY_IP\033[0m  端口: \033[33m$ALIYUN_PORT\033[0m"
echo -e "用户 ID: \033[33m$UUID\033[0m"
echo -e "落地出口: \033[33m$USA_IP\033[0m"
echo -e "--------------------------------------------------"
echo -e "VMess 链接:"
echo -e "\033[32m$VMESS_LINK\033[0m"
echo -e "--------------------------------------------------"
echo -e "扫描二维码 (UTF8 小型化):"
echo "$VMESS_LINK" | qrencode -t UTF8
echo -e "\033[32m==================================================\033[0m"
