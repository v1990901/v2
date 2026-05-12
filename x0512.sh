#!/bin/bash

# ====================================================
# V2Ray 跨境矩阵管理脚本 V2V5 (双出口/防泄露增强版)
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
    echo -e "${green}正在安装系统依赖并优化内核...${plain}"
    apt-get update && apt-get install -y curl wget unzip coreutils python3
    
    # 开启 BBR 加速
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # 安装 V2Ray (支持镜像加速)
    if ! command -v v2ray &> /dev/null; then
        echo -e "${yellow}正在安装 V2Ray 核心...${plain}"
        bash <(curl -sL https://mirror.ghproxy.com/https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
    fi

    # 自动创建 Service 防止 Unit not found
    cat > /etc/systemd/system/v2ray.service <<EOF
[Unit]
Description=V2Ray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/v2ray run -c /usr/local/etc/v2ray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable v2ray
    
    # 初始化空配置
    mkdir -p /usr/local/etc/v2ray
    echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > "$CONFIG_FILE"
    systemctl restart v2ray
    echo -e "${green}环境准备就绪！${plain}"
}

# 2. 增加节点 (含出口模式选择)
add_node() {
    echo -e "\n${yellow}--- 添加新节点 (V2V5 矩阵) ---${plain}"
    read -p "1. 节点备注 (如: 美国TK01): " ps
    read -p "2. 监听端口 (如: 54321): " l_port
    
    echo -e "\n${green}请选择出口模式：${plain}"
    echo "1. 落地模式 (转发至静态住宅IP，权重高，适合养号)"
    echo "2. 直连模式 (直接使用本服务器出口，适合普通外贸)"
    read -p "请选择 [1-2]: " exit_mode

    if [ "$exit_mode" == "1" ]; then
        read -p "落地IP (Socks5): " r_ip
        read -p "落地端口: " r_port
        read -p "Socks5账号: " s_user
        read -p "Socks5密码: " s_pass
        outbound_proto="socks"
    else
        outbound_proto="freedom"
    fi
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    tag="tag_$l_port"

    # 使用 Python 精准处理 JSON
    python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)

new_in = {
    'tag': 'in_$tag',
    'port': int('$l_port'),
    'protocol': 'vmess',
    'settings': {'clients': [{'id': '$uuid'}]},
    'sniffing': {'enabled': True, 'destOverride': ['http', 'tls'], 'routeOnly': True}
}

if '$outbound_proto' == 'socks':
    new_out = {
        'tag': '$tag',
        'protocol': 'socks',
        'settings': {'servers': [{'address': '$r_ip', 'port': int('$r_port'), 'users': [{'user': '$s_user', 'pass': '$s_pass'}]}]}
    }
else:
    new_out = {'tag': '$tag', 'protocol': 'freedom'}

new_rule = {
    'type': 'field',
    'inboundTag': ['in_$tag'],
    'outboundTag': '$tag'
}

data['inbounds'].append(new_in)
data['outbounds'].insert(0, new_out)
data['routing']['rules'].append(new_rule)

with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    systemctl restart v2ray
    
    # 生成 VMess 链接
    my_ip=$(curl -s http://checkip.amazonaws.com)
    vm_json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none"}' "$ps" "$my_ip" "$l_port" "$uuid")
    link="vmess://$(echo -n "$vm_json" | base64 | tr -d '\n')"
    
    echo -e "\n${green}✅ 节点配置成功！${plain}"
    echo -e "监听端口 : ${yellow}$l_port${plain}"
    echo -e "出口模式 : ${yellow}$([ "$exit_mode" == "1" ] && echo "落地住宅IP" || echo "直连中转IP")${plain}"
    echo -e "VMess 链接: ${yellow}$link${plain}"
}

# 菜单循环... (此处省略部分展示类函数，逻辑与 V9 一致)
while true; do
    echo -e "\n${green}V2V5 矩阵管理系统${plain}"
    echo "1. 安装环境"
    echo "2. 增加节点 (可选模式)"
    echo "3. 查看列表"
    echo "4. 删除节点"
    echo "0. 退出"
    read -p "选择: " opt
    case $opt in
        1) prepare_env ;;
        2) add_node ;;
        3) python3 -c "import json; print(json.dumps(json.load(open('$CONFIG_FILE')), indent=2))" ;;
        4) read -p "输入端口: " p; # 删除逻辑... ;;
        0) exit 0 ;;
    esac
done