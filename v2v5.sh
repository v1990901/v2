#!/bin/bash

# ====================================================
# V2Ray 社媒矩阵管理脚本 V9 (镜像加速修复版)
# ====================================================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CONFIG_FILE="/usr/local/etc/v2ray/config.json"

# 权限自检
[[ $EUID -ne 0 ]] && echo -e "${red}错误：请以 root 权限运行！${plain}" && exit 1

# 1. 环境安装与加速
prepare_env() {
    echo -e "${green}正在安装系统依赖...${plain}"
    apt-get update && apt-get install -y curl wget unzip coreutils base64 python3
    
    # 开启内核 BBR 加速
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # 核心安装：尝试官方源和镜像源
    if ! command -v v2ray &> /dev/null; then
        echo -e "${yellow}正在通过镜像加速下载 V2Ray 核心...${plain}"
        bash <(curl -L https://mirror.ghproxy.com/https://raw.githubusercontent.com/v2fly/fclones/main/install-release.sh)
    fi

    # 手动补偿：解决 Unit not found 问题
    if [ ! -f /etc/systemd/system/v2ray.service ]; then
        echo -e "${yellow}手动修复服务映射...${plain}"
        cat <<EOF >/etc/systemd/system/v2ray.service
[Unit]
Description=V2Ray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/v2ray run -c /usr/local/etc/v2ray/config.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable v2ray
    systemctl restart v2ray
    
    if systemctl is-active --quiet v2ray; then
        echo -e "${green}V2Ray 服务已成功激活并运行！${plain}"
    else
        echo -e "${red}错误：核心启动失败，请检查端口是否冲突。${plain}"
    fi
}

# 2. 增加节点
add_node() {
    if [ ! -f $CONFIG_FILE ] || [ ! -s $CONFIG_FILE ]; then
        mkdir -p /usr/local/etc/v2ray
        echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > $CONFIG_FILE
    fi

    echo -e "\n${yellow}--- 添加新节点 (社媒矩阵专用) ---${plain}"
    read -p "1. 节点备注 (如: 美国TK01): " ps
    read -p "2. 中转监听端口 (如: 10001): " l_port
    read -p "3. 落地IP (Socks5): " r_ip
    read -p "4. 落地端口: " r_port
    read -p "5. Socks5 账号: " s_user
    read -p "6. Socks5 密码: " s_pass
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    tag="tag_$l_port"

    # 构建配置 (开启嗅探防止DNS泄露 & TCP Fast Open)
    NEW_IN=$(printf '{"tag":"in_%s","port":%s,"protocol":"vmess","settings":{"clients":[{"id":"%s"}]},"sniffing":{"enabled":true,"destOverride":["http","tls"],"routeOnly":true},"streamSettings":{"sockopt":{"tcpFastOpen":true}}}' "$tag" "$l_port" "$uuid")
    NEW_OUT=$(printf '{"tag":"%s","protocol":"socks","settings":{"servers":[{"address":"%s","port":%s,"users":[{"user":"%s","pass":"%s"}]}]},"streamSettings":{"sockopt":{"tcpFastOpen":true}}}' "$tag" "$r_ip" "$r_port" "$s_user" "$s_pass")
    NEW_RULE=$(printf '{"type":"field","inboundTag":["in_%s"],"outboundTag":"%s"}' "$tag" "$tag")

    # Python 安全写入
    python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)
data['inbounds'].append($NEW_IN)
data['outbounds'].insert(0, $NEW_OUT)
data['routing']['rules'].append($NEW_RULE)
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    systemctl restart v2ray
    
    my_ip=$(curl -s http://checkip.amazonaws.com)
    vm_json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none"}' "$ps" "$my_ip" "$l_port" "$uuid")
    link="vmess://$(echo -n "$vm_json" | base64 | tr -d '\n')"
    qr_url="https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=$link"
    
    echo -e "\n${green}✅ 配置成功！${plain}"
    echo -e "VMess 链接: ${yellow}$link${plain}"
    echo -e "二维码查看: ${yellow}$qr_url${plain}\n"
}

# 3. 查看节点列表
list_nodes() {
    if [ ! -f $CONFIG_FILE ]; then echo -e "${red}暂无配置。${plain}"; return 1; fi
    echo -e "\n${yellow}--- 运行中的端口列表 ---${plain}"
    echo -e "---------------------------------------------------------------"
    printf "%-10s | %-20s | %-15s\n" "端口" "类型" "落地出口IP"
    echo -e "---------------------------------------------------------------"
    python3 -c "
import json
data = json.load(open('$CONFIG_FILE'))
for ib in data.get('inbounds', []):
    port = ib['port']
    tag = ib['tag'].replace('in_', '')
    r_ip = 'Unknown'
    for ob in data.get('outbounds', []):
        if ob.get('tag') == tag:
            r_ip = ob.get('settings', {}).get('servers', [{}])[0].get('address', 'Unknown')
    print(f'{port: <10} | 矩阵隔离节点         | {r_ip:<15}')
"
}

# 4. 删除节点
delete_node() {
    list_nodes || return
    read -p "请输入要删除的 [端口号]: " del_port
    python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)
t = 'tag_' + '$del_port'; it = 'in_' + t
data['inbounds'] = [i for i in data['inbounds'] if i['port'] != int('$del_port')]
data['outbounds'] = [o for o in data['outbounds'] if o.get('tag') != t]
data['routing']['rules'] = [r for r in data['routing']['rules'] if it not in r.get('inboundTag', [])]
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    systemctl restart v2ray
    echo -e "${green}✅ 节点已成功移除。${plain}"
}

# 主菜单
while true; do
    echo -e "\n${green}V2Ray 矩阵管理系统 V9${plain}"
    echo "---------------------------"
    echo "1. 开启环境与加速 (核心安装)"
    echo "2. 增加落地节点 (备注/二维码)"
    echo "3. 查看节点列表"
    echo "4. 删除指定节点"
    echo "0. 退出"
    read -p "请选择: " opt
    case $opt in
        1) prepare_env ;;
        2) add_node ;;
        3) list_nodes ;;
        4) delete_node ;;
        0) exit 0 ;;
    esac
done
