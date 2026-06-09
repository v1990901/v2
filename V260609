#!/bin/bash

# ====================================================
# V2Ray 社媒矩阵管理脚本 V9 (智能健壮容错版)
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
    apt-get update && apt-get install -y curl wget unzip coreutils python3
    
    # 开启内核 BBR 加速
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # 核心安装：依次尝试官方源和多个镜像源
    if ! command -v v2ray &> /dev/null; then
        echo -e "${yellow}正在下载 V2Ray 核心，尝试官方源...${plain}"
        
        INSTALL_SUCCESS=false
        
        # 方式1：官方源
        if bash <(curl -sL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh); then
            INSTALL_SUCCESS=true
        fi

        # 方式2：ghproxy 镜像
        if [ "$INSTALL_SUCCESS" = false ]; then
            echo -e "${yellow}官方源失败，尝试 ghproxy 镜像...${plain}"
            if bash <(curl -sL https://mirror.ghproxy.com/https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh); then
                INSTALL_SUCCESS=true
            fi
        fi

        # 方式3：ghfast 镜像
        if [ "$INSTALL_SUCCESS" = false ]; then
            echo -e "${yellow}尝试 ghfast 镜像...${plain}"
            if bash <(curl -sL https://ghfast.top/https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh); then
                INSTALL_SUCCESS=true
            fi
        fi

        # 方式4：手动下载二进制
        if [ "$INSTALL_SUCCESS" = false ]; then
            echo -e "${yellow}脚本安装均失败，尝试手动下载二进制...${plain}"
            ARCH=$(uname -m)
            case $ARCH in
                x86_64) V2_ARCH="64" ;;
                aarch64) V2_ARCH="arm64-v8a" ;;
                armv7l) V2_ARCH="arm32-v7a" ;;
                *) V2_ARCH="64" ;;
            esac
            
            V2_VERSION=$(curl -sL https://api.github.com/repos/v2fly/v2ray-core/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
            [ -z "$V2_VERSION" ] && V2_VERSION="v5.16.1"  # 回退到已知稳定版本
            
            DL_URL="https://mirror.ghproxy.com/https://github.com/v2fly/v2ray-core/releases/download/${V2_VERSION}/v2ray-linux-${V2_ARCH}.zip"
            echo -e "${yellow}下载: $DL_URL${plain}"
            
            if wget -O /tmp/v2ray.zip "$DL_URL"; then
                mkdir -p /tmp/v2ray_extract /usr/local/bin /usr/local/etc/v2ray
                unzip -o /tmp/v2ray.zip -d /tmp/v2ray_extract
                cp /tmp/v2ray_extract/v2ray /usr/local/bin/v2ray
                chmod +x /usr/local/bin/v2ray
                rm -rf /tmp/v2ray.zip /tmp/v2ray_extract
                INSTALL_SUCCESS=true
                echo -e "${green}手动二进制安装成功！${plain}"
            else
                echo -e "${red}错误：所有安装方式均失败，请检查服务器网络后重试。${plain}"
                return 1
            fi
        fi
    else
        echo -e "${green}V2Ray 已安装，跳过下载。${plain}"
    fi

    # 确保配置目录存在
    mkdir -p /usr/local/etc/v2ray

    # 手动补偿：解决 Unit not found 问题
    if [ ! -f /etc/systemd/system/v2ray.service ]; then
        echo -e "${yellow}手动创建服务文件...${plain}"
        cat > /etc/systemd/system/v2ray.service <<EOF
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/v2ray run -c /usr/local/etc/v2ray/config.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
        echo -e "${green}服务服务文件创建成功。${plain}"
    fi

    systemctl daemon-reload
    systemctl enable v2ray

    # 初始化空配置（如不存在）
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > "$CONFIG_FILE"
    fi

    systemctl restart v2ray
    sleep 2
    
    if systemctl is-active --quiet v2ray; then
        echo -e "${green}✅ V2Ray 服务已成功激活并运行！${plain}"
    else
        echo -e "${red}❌ 错误：V2Ray 启动失败，查看日志：${plain}"
        journalctl -u v2ray -n 20 --no-pager
    fi
}

# 2. 增加节点
add_node() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        mkdir -p /usr/local/etc/v2ray
        echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > "$CONFIG_FILE"
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

    # Python 安全写入配置 (新增结构智能自检，杜绝 KeyError)
    python3 -c "
import json, sys, os

data = {}
if os.path.exists('$CONFIG_FILE') and os.path.getsize('$CONFIG_FILE') > 0:
    try:
        with open('$CONFIG_FILE', 'r') as f:
            data = json.load(f)
    except Exception:
        data = {}

if not isinstance(data, dict):
    data = {}

# 兜底初始化，防止任何基础键缺失
if 'inbounds' not in data: data['inbounds'] = []
if 'outbounds' not in data: data['outbounds'] = [{'tag':'direct','protocol':'freedom'}]
if 'routing' not in data: data['routing'] = {'rules':[]}
if 'rules' not in data['routing']: data['routing']['rules'] = []

new_in = {
    'tag': 'in_$tag',
    'port': int('$l_port'),
    'protocol': 'vmess',
    'settings': {'clients': [{'id': '$uuid'}]},
    'sniffing': {'enabled': True, 'destOverride': ['http', 'tls'], 'routeOnly': True},
    'streamSettings': {'sockopt': {'tcpFastOpen': True}}
}

new_out = {
    'tag': '$tag',
    'protocol': 'socks',
    'settings': {'servers': [{'address': '$r_ip', 'port': int('$r_port'), 'users': [{'user': '$s_user', 'pass': '$s_pass'}]}]},
    'streamSettings': {'sockopt': {'tcpFastOpen': True}}
}

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

print('配置写入成功')
"
    if [ $? -ne 0 ]; then
        echo -e "${red}❌ 配置写入失败，请检查 JSON 格式。${plain}"
        return 1
    fi

    systemctl restart v2ray
    sleep 1

    my_ip=$(curl -s --max-time 5 http://checkip.amazonaws.com || curl -s --max-time 5 https://api.ipify.org)
    vm_json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none"}' "$ps" "$my_ip" "$l_port" "$uuid")
    link="vmess://$(echo -n "$vm_json" | base64 | tr -d '\n')"
    qr_url="https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$link'))")"
    
    echo -e "\n${green}✅ 节点配置成功！${plain}"
    echo -e "节点备注 : ${yellow}$ps${plain}"
    echo -e "监听端口 : ${yellow}$l_port${plain}"
    echo -e "落地IP   : ${yellow}$r_ip:$r_port${plain}"
    echo -e "VMess 链接: ${yellow}$link${plain}"
    echo -e "二维码查看: ${yellow}$qr_url${plain}\n"
}

# 3. 查看节点列表
list_nodes() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${red}暂无配置文件。${plain}"
        return 1
    fi
    echo -e "\n${yellow}--- 运行中的节点列表 ---${plain}"
    echo -e "---------------------------------------------------------------"
    printf "%-10s | %-20s | %-20s\n" "端口" "标签" "落地出口IP"
    echo -e "---------------------------------------------------------------"
    python3 -c "
import json
try:
    data = json.load(open('$CONFIG_FILE'))
    inbounds = data.get('inbounds', [])
    if not inbounds:
        print('  (暂无节点)')
    for ib in inbounds:
        port = ib.get('port', 'N/A')
        tag = ib.get('tag', '').replace('in_', '')
        r_ip = 'Unknown'
        for ob in data.get('outbounds', []):
            if ob.get('tag') == tag:
                servers = ob.get('settings', {}).get('servers', [])
                if servers:
                    r_ip = servers[0].get('address', 'Unknown')
        print(f'{str(port):<10} | {tag:<20} | {r_ip:<20}')
except Exception as e:
    print(f'读取配置失败: {e}')
"
    echo -e "---------------------------------------------------------------"
}

# 4. 删除节点
delete_node() {
    list_nodes || return
    read -p "请输入要删除的 [端口号]: " del_port
    
    python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)

t = 'tag_$del_port'
it = 'in_' + t

# 容错过滤，如果结构不标准则赋予默认空列表防止爆错
if 'inbounds' not in data: data['inbounds'] = []
if 'outbounds' not in data: data['outbounds'] = []
if 'routing' not in data: data['routing'] = {'rules':[]}
if 'rules' not in data['routing']: data['routing']['rules'] = []

before = len(data['inbounds'])
data['inbounds']  = [i for i in data['inbounds']  if i.get('port') != int('$del_port')]
data['outbounds'] = [o for o in data['outbounds'] if o.get('tag') != t]
data['routing']['rules'] = [r for r in data['routing']['rules'] if it not in r.get('inboundTag', [])]

after = len(data['inbounds'])
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)

if before != after:
    print('节点已移除')
else:
    print('未找到该端口，请确认端口号是否正确')
"
    systemctl restart v2ray
    echo -e "${green}✅ 操作完成。${plain}"
}

# 5. 查看服务状态
show_status() {
    echo -e "\n${yellow}--- V2Ray 服务状态 ---${plain}"
    systemctl status v2ray --no-pager
    echo -e "\n${yellow}--- 最近日志 ---${plain}"
    journalctl -u v2ray -n 30 --no-pager
}

# 主菜单
while true; do
    echo -e "\n${green}=============================\n  V2Ray 矩阵管理系统 V9\n=============================${plain}"
    echo "1. 安装/修复环境 (核心安装)"
    echo "2. 增加落地节点"
    echo "3. 查看节点列表"
    echo "4. 删除指定节点"
    echo "5. 查看服务状态与日志"
    echo "0. 退出"
    echo -e "${yellow}-----------------------------${plain}"
    read -p "请选择 [0-5]: " opt
    case $opt in
        1) prepare_env ;;
        2) add_node ;;
        3) list_nodes ;;
        4) delete_node ;;
        5) show_status ;;
        0) echo -e "${green}再见！${plain}"; exit 0 ;;
        *) echo -e "${red}无效选项，请重新选择。${plain}" ;;
    esac
done
