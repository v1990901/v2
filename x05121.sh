#!/bin/bash

# ====================================================
# V2Ray 跨境矩阵管理脚本 V2V5 (修复版)
# ====================================================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CONFIG_FILE="/usr/local/etc/v2ray/config.json"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${red}错误：请以 root 权限运行！${plain}" && exit 1

# 环境准备
prepare_env() {
    echo -e "${green}正在安装系统依赖并开启 BBR...${plain}"
    apt-get update && apt-get install -y curl wget unzip coreutils python3
    
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    if ! command -v v2ray &> /dev/null; then
        echo -e "${yellow}安装 V2Ray 核心...${plain}"
        bash <(curl -sL https://mirror.ghproxy.com/https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
    fi

    mkdir -p /usr/local/etc/v2ray
    systemctl enable v2ray
    echo -e "${green}基础环境安装完成。${plain}"
}

# 增加节点
add_node() {
    echo -e "\n${yellow}--- 添加新节点 ---${plain}"
    read -p "1. 节点备注: " ps
    read -p "2. 监听端口: " l_port
    
    echo -e "选择出口模式:\n 1. 转发落地 (Socks5)\n 2. 直接中转站出口"
    read -p "选择 [1-2]: " mode

    if [ "$mode" == "1" ]; then
        read -p "落地IP: " r_ip
        read -p "落地端口: " r_port
        read -p "落地账号: " s_user
        read -p "落地密码: " s_pass
        out_proto="socks"
    else
        out_proto="freedom"
    fi
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    tag="tag_$l_port"

    # 使用 Python 处理 JSON 防止语法错误
    python3 -c "
import json, os
if not os.path.exists('$CONFIG_FILE'):
    data = {'inbounds':[], 'outbounds':[{'tag':'direct','protocol':'freedom'}], 'routing':{'rules':[]}}
else:
    with open('$CONFIG_FILE', 'r') as f: data = json.load(f)

new_in = {
    'tag': 'in_$tag', 'port': int('$l_port'), 'protocol': 'vmess',
    'settings': {'clients': [{'id': '$uuid'}]},
    'sniffing': {'enabled': True, 'destOverride': ['http', 'tls'], 'routeOnly': True}
}

if '$out_proto' == 'socks':
    new_out = {
        'tag': '$tag', 'protocol': 'socks',
        'settings': {'servers': [{'address': '$r_ip', 'port': int('$r_port'), 'users': [{'user': '$s_user', 'pass': '$s_pass'}]}]}
    }
else:
    new_out = {'tag': '$tag', 'protocol': 'freedom'}

data['inbounds'].append(new_in)
data['outbounds'].insert(0, new_out)
data['routing']['rules'].append({'type': 'field', 'inboundTag': ['in_$tag'], 'outboundTag': '$tag'})
data['routing']['rules'].append({'type': 'field', 'port': '53', 'outboundTag': '$tag'})

with open('$CONFIG_FILE', 'w') as f: json.dump(data, f, indent=2)
"
    systemctl restart v2ray
    
    my_ip=$(curl -s http://checkip.amazonaws.com)
    vm_json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none"}' "$ps" "$my_ip" "$l_port" "$uuid")
    echo -e "${green}✅ 节点已生成：${plain}\nvmess://$(echo -n "$vm_json" | base64 | tr -d '\n')\n"
}

# 主菜单
while true; do
    echo -e "${green}V2V5 矩阵管理系统${plain}"
    echo "1. 安装/修复环境"
    echo "2. 增加节点"
    echo "3. 查看日志"
    echo "0. 退出"
    read -p "请选择: " opt
    case "$opt" in
        1) prepare_env ;;
        2) add_node ;;
        3) journalctl -u v2ray -n 20 --no-pager ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done