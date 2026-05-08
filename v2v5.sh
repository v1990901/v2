#!/bin/bash

# ====================================================
# V2Ray 社媒矩阵管理脚本 V7 (最终修复版)
# 功能：BBR加速 / 多落地隔离 / 防DNS泄露 / 备注管理 / 交互增删
# ====================================================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CONFIG_FILE="/usr/local/etc/v2ray/config.json"

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain}必须使用 root 用户运行！" && exit 1

# 1. 系统环境与加速优化
prepare_env() {
    echo -e "${green}正在配置系统环境...${plain}"
    apt-get update && apt-get install -y curl wget unzip coreutils base64 python3
    
    # 开启内核 BBR 加速
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        echo -e "${green}BBR 加速已开启。${plain}"
    fi

    # 核心安装逻辑：解决 service not found 问题
    if ! command -v v2ray &> /dev/null; then
        echo -e "${yellow}未检测到 V2Ray 核心，正在尝试安装...${plain}"
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fclones/main/install-release.sh)
    fi

    # 再次检查服务状态
    if [ ! -f /etc/systemd/system/v2ray.service ]; then
        echo -e "${red}安装失败：无法创建服务文件。尝试备用安装方式...${plain}"
        # 强制手动创建服务链接（针对某些 Ubuntu 版本）
        ln -s /usr/local/lib/systemd/system/v2ray.service /etc/systemd/system/v2ray.service 2>/dev/null
    fi

    systemctl daemon-reload
    systemctl enable v2ray
    systemctl restart v2ray
    
    if systemctl is-active --quiet v2ray; then
        echo -e "${green}V2Ray 服务已正常启动！${plain}"
    else
        echo -e "${red}警告：V2Ray 服务仍未启动，请检查防火墙或网络连接。${plain}"
    fi
}

# 2. 查看节点列表
list_nodes() {
    if [ ! -f $CONFIG_FILE ] || [ ! -s $CONFIG_FILE ]; then
        echo -e "${yellow}当前没有任何节点配置。${plain}"
        return 1
    fi
    echo -e "\n${yellow}--- 当前运行节点列表 ---${plain}"
    echo -e "---------------------------------------------------------------"
    printf "%-10s | %-20s | %-15s\n" "端口" "节点备注" "落地出口IP"
    echo -e "---------------------------------------------------------------"
    python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    for ib in data.get('inbounds', []):
        port = ib['port']
        tag = ib['tag'].replace('in_', '')
        r_ip = 'Unknown'
        for ob in data.get('outbounds', []):
            if ob.get('tag') == tag:
                r_ip = ob.get('settings', {}).get('servers', [{}])[0].get('address', 'Unknown')
        print(f'{port: <10} | 矩阵节点_{port: <13} | {r_ip:<15}')
except Exception as e:
    print('解析错误:', e)
"
    echo -e "---------------------------------------------------------------\n"
}

# 3. 增加节点
add_node() {
    # 如果文件不存在，初始化基础 JSON 结构
    if [ ! -f $CONFIG_FILE ] || [ ! -s $CONFIG_FILE ]; then
        mkdir -p /usr/local/etc/v2ray
        echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > $CONFIG_FILE
    fi

    echo -e "\n${yellow}请输入新节点信息：${plain}"
    read -p "1. 节点备注 (如 韩国TK01): " ps
    read -p "2. 中转端口 (如 10001): " l_port
    read -p "3. 落地代理IP: " r_ip
    read -p "4. 落地代理端口: " r_port
    read -p "5. Socks5 账号: " s_user
    read -p "6. Socks5 密码: " s_pass
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    tag="tag_$l_port"

    # 构建配置 (强制开启 sniffing 和 routeOnly 防止 DNS 泄露)
    NEW_IN=$(printf '{"tag":"in_%s","port":%s,"protocol":"vmess","settings":{"clients":[{"id":"%s"}]},"sniffing":{"enabled":true,"destOverride":["http","tls"],"routeOnly":true},"streamSettings":{"sockopt":{"tcpFastOpen":true}}}' "$tag" "$l_port" "$uuid")
    NEW_OUT=$(printf '{"tag":"%s","protocol":"socks","settings":{"servers":[{"address":"%s","port":%s,"users":[{"user":"%s","pass":"%s"}]}]},"streamSettings":{"sockopt":{"tcpFastOpen":true}}}' "$tag" "$r_ip" "$r_port" "$s_user" "$s_pass")
    NEW_RULE=$(printf '{"type":"field","inboundTag":["in_%s"],"outboundTag":"%s"}' "$tag" "$tag")

    # 利用 Python 安全写入
    python3 -c "
import json, sys
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)
data['inbounds'].append($NEW_IN)
data['outbounds'].insert(0, $NEW_OUT)
data['routing']['rules'].append($NEW_RULE)
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    systemctl restart v2ray
    
    # 生成链接与二维码
    my_ip=$(curl -s http://checkip.amazonaws.com)
    vm_json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none"}' "$ps" "$my_ip" "$l_port" "$uuid")
    link="vmess://$(echo -n "$vm_json" | base64 | tr -d '\n')"
    qr_url="https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=$link"
    
    echo -e "\n${green}✅ 节点已成功上线！${plain}"
    echo -e "节点链接: ${yellow}$link${plain}"
    echo -e "二维码查看: ${yellow}$qr_url${plain}\n"
}

# 4. 删除节点
delete_node() {
    list_nodes || return
    read -p "请输入要删除的 [中转端口]: " del_port
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
    echo -e "${green}✅ 节点 $del_port 已移除。${plain}"
}

# 5. 主循环菜单
while true; do
    echo -e "
  ${green}V2Ray 矩阵加速管理系统 (最终修复版)${plain}
  ---------------------------
  ${green}1.${plain} 安装/修复环境 (含开启加速)
  ${green}2.${plain} 增加节点 (支持备注/二维码/防检测)
  ${green}3.${plain} 查看当前节点列表
  ${green}4.${plain} 删除指定节点
  ${green}0.${plain} 退出脚本
  ---------------------------"
    read -p "选择操作: " opt
    case $opt in
        1) prepare_env ;;
        2) add_node ;;
        3) list_nodes ;;
        4) delete_node ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done
