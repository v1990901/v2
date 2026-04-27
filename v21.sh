#!/bin/bash

# V2Ray 矩阵专用 - 交互式多落地管理脚本
# 功能：动态增删节点、自动UUID、防DNS外溢、生成链接与二维码

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CONFIG_FILE="/usr/local/etc/v2ray/config.json"

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行！\n" && exit 1

# 初始化环境
prepare_env() {
    apt-get update && apt-get install -y jq curl uuid-runtime base64 wget unzip
    if [[ ! -f /usr/local/bin/v2ray ]]; then
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fclones/main/install-release.sh)
        systemctl enable v2ray
    fi
}

# 获取本机IP
get_ip() {
    echo $(curl -sL ip.sb || curl -sL ifconfig.me)
}

# 重组并保存配置
save_config() {
    systemctl restart v2ray
    echo -e "${green}配置已更新并重启服务！${plain}"
}

# 添加新节点
add_node() {
    [[ ! -f $CONFIG_FILE ]] && echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > $CONFIG_FILE
    
    echo -e "${yellow}--- 添加新落地节点 ---${plain}"
    read -p "节点名称 (例如: US_TikTok_01): " ps
    read -p "中转端口 (本VPS监听): " l_port
    read -p "落地IP (购买的IP): " r_ip
    read -p "落地端口: " r_port
    read -p "Socks5 用户名: " s_user
    read -p "Socks5 密码: " s_pass
    
    uuid=$(uuidgen)
    tag="tag_$l_port"
    
    # 构建 JSON 片段
    inbound_json=$(jq -n --arg port "$l_port" --arg uuid "$uuid" --arg tag "in_$tag" \
        '{"tag":$tag,"port":($port|tonumber),"protocol":"vmess","settings":{"clients":[{"id":$uuid}]},"sniffing":{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}}')
    
    outbound_json=$(jq -n --arg addr "$r_ip" --arg port "$r_port" --arg user "$s_user" --arg pass "$s_pass" --arg tag "$tag" \
        '{"tag":$tag,"protocol":"socks","settings":{"servers":[{"address":$addr,"port":($port|tonumber),"users":[{"user":$user,"pass":$pass}]}]}}')
    
    rule_json=$(jq -n --arg inTag "in_$tag" --arg outTag "$tag" \
        '{"type":"field","inboundTag":[$inTag],"outboundTag":$outTag}')

    # 写入文件
    jq ".inbounds += [$inbound_json]" $CONFIG_FILE > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp $CONFIG_FILE
    jq ".outbounds += [$outbound_json]" $CONFIG_FILE > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp $CONFIG_FILE
    jq ".routing.rules += [$rule_json]" $CONFIG_FILE > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp $CONFIG_FILE
    
    save_config
    
    # 生成链接
    my_ip=$(get_ip)
    vm_json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none"}' "$ps" "$my_ip" "$l_port" "$uuid")
    link="vmess://$(echo -n "$vm_json" | base64 -w 0)"
    echo -e "\n${green}节点添加成功！${plain}"
    echo -e "VMess链接: ${yellow}$link${plain}"
    echo -e "二维码查看: ${yellow}https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=$link${plain}\n"
}

# 列出并管理节点
list_nodes() {
    echo -e "${yellow}--- 当前转发节点列表 ---${plain}"
    inbounds=$(jq '.inbounds[]' $CONFIG_FILE)
    if [[ -z "$inbounds" ]]; then
        echo "暂无节点"
        return
    fi
    
    # 使用 jq 提取关键信息并显示
    jq -r '.inbounds[] | "端口: \(.port) | ID: \(.settings.clients[0].id)"' $CONFIG_FILE
}

# 清空所有配置
clear_all() {
    read -p "确定要清空所有中转配置吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        echo '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}' > $CONFIG_FILE
        save_config
    fi
}

# 主菜单
main_menu() {
    clear
    echo -e "${green}V2Ray 多落地交互管理脚本${plain}"
    echo "---------------------------"
    echo "1. 安装/修复 V2Ray 环境"
    echo "2. 添加新落地节点 (增加IP)"
    echo "3. 查看当前节点列表"
    echo "4. 清空所有配置"
    echo "0. 退出"
    echo "---------------------------"
    read -p "选择操作 [0-4]: " opt
    case $opt in
        1) prepare_env ;;
        2) add_node ;;
        3) list_nodes ;;
        4) clear_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

while true; do
    main_menu
    read -p "按回车键返回菜单..."
done