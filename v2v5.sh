#!/bin/bash

# V2Ray 矩阵多落地管理脚本 - 工业级防封版
# 适用：一台香港中转机 -> 对接多个三方落地IP

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CONFIG_FILE="/usr/local/etc/v2ray/config.json"

# 检查Root权限
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain}必须使用 root 用户运行！" && exit 1

# 1. 环境安装与系统优化
prepare_env() {
    echo -e "${green}正在配置系统环境与加速...${plain}"
    apt-get update && apt-get install -y curl wget unzip coreutils base64 python3
    
    # 开启内核 BBR 加速
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # 安装 V2Ray 核心
    if [ ! -f /usr/local/bin/v2ray ]; then
        echo -e "${yellow}安装 V2Ray 官方核心...${plain}"
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fclones/main/install-release.sh)
        systemctl enable v2ray
    fi
    echo -e "${green}环境安装成功，BBR 加速已开启。${plain}"
}

# 2. 增加节点
add_node() {
    if [ ! -f $CONFIG_FILE ]; then
        mkdir -p /usr/local/etc/v2ray
        echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > $CONFIG_FILE
    fi

    echo -e "\n${yellow}--- [添加新节点配置] ---${plain}"
    read -p "1. 节点备注 (用于小火箭显示，如: 韩国TK-01): " ps
    read -p "2. 本机中转端口 (不可重复，如: 10001): " l_port
    read -p "3. 落地代理IP: " r_ip
    read -p "4. 落地代理端口: " r_port
    read -p "5. Socks5 账号: " s_user
    read -p "6. Socks5 密码: " s_pass
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    tag="tag_$l_port"

    # 构建 JSON 配置 (开启嗅探防止DNS泄露)
    NEW_IN=$(printf '{"tag":"in_%s","port":%s,"protocol":"vmess","settings":{"clients":[{"id":"%s"}]},"sniffing":{"enabled":true,"destOverride":["http","tls"],"routeOnly":true},"streamSettings":{"sockopt":{"tcpFastOpen":true}}}' "$tag" "$l_port" "$uuid")
    NEW_OUT=$(printf '{"tag":"%s","protocol":"socks","settings":{"servers":[{"address":"%s","port":%s,"users":[{"user":"%s","pass":"%s"}]}]},"streamSettings":{"sockopt":{"tcpFastOpen":true}}}' "$tag" "$r_ip" "$r_port" "$s_user" "$s_pass")
    NEW_RULE=$(printf '{"type":"field","inboundTag":["in_%s"],"outboundTag":"%s"}' "$tag" "$tag")

    # 利用 Python 写入配置
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
    
    # 获取本机IP并生成链接
    my_ip=$(curl -s http://checkip.amazonaws.com)
    vm_json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none"}' "$ps" "$my_ip" "$l_port" "$uuid")
    link="vmess://$(echo -n "$vm_json" | base64 | tr -d '\n')"
    qr_url="https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=$link"
    
    echo -e "\n${green}======================================"
    echo -e "✅ 节点添加成功！"
    echo -e "备注: ${yellow}$ps${plain}"
    echo -e "VMess链接: ${green}$link${plain}"
    echo -e "二维码查看: ${green}$qr_url${plain}"
    echo -e "======================================${plain}\n"
}

# 3. 查看节点列表
list_nodes() {
    if [ ! -f $CONFIG_FILE ]; then
        echo -e "${red}配置文件为空，请先添加节点。${plain}"
        return 1
    fi
    echo -e "\n${yellow}--- 当前运行中的节点 ---${plain}"
    echo -e "---------------------------------------------------------------"
    printf "%-10s | %-20s | %-15s\n" "端口" "备注/类型" "落地出口IP"
    echo -e "---------------------------------------------------------------"
    python3 -c "
import json
try:
    data = json.load(open('$CONFIG_FILE'))
    for ib in data['inbounds']:
        port = ib['port']
        tag = ib['tag'].replace('in_', '')
        r_ip = 'Unknown'
        for ob in data['outbounds']:
            if ob.get('tag') == tag:
                r_ip = ob.get('settings', {}).get('servers', [{}])[0].get('address', 'Unknown')
        print(f'{port: <10} | 矩阵中转节点         | {r_ip:<15}')
except:
    print('解析失败')
"
    echo -e "---------------------------------------------------------------\n"
}

# 4. 删除节点
delete_node() {
    list_nodes || return
    read -p "请输入要删除节点的 [端口号]: " del_port
    [[ -z "$del_port" ]] && return

    python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)
tag = 'tag_' + '$del_port'
in_tag = 'in_' + tag

data['inbounds'] = [i for i in data['inbounds'] if i['port'] != int('$del_port')]
data['outbounds'] = [o for o in data['outbounds'] if o.get('tag') != tag]
data['routing']['rules'] = [r for r in data['routing']['rules'] if in_tag not in r.get('inboundTag', [])]

with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    systemctl restart v2ray
    echo -e "${green}✅ 端口 $del_port 关联的节点已成功删除。${plain}"
}

# 5. 主循环菜单
while true; do
    echo -e "
  ${green}V2Ray 矩阵加速管理脚本 (防封专用)${plain}
  ---------------------------
  ${green}1.${plain} 安装环境 (含开启 BBR 加速)
  ${green}2.${plain} 增加节点 (自定义备注/生成二维码)
  ${green}3.${plain} 查看所有节点列表
  ${green}4.${plain} 删除指定节点
  ${green}0.${plain} 退出脚本
  ---------------------------"
    read -p "请选择: " opt
    case $opt in
        1) prepare_env ;;
        2) add_node ;;
        3) list_nodes ;;
        4) delete_node ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
