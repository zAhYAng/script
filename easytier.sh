#!/bin/bash

# -------------------------------
# 定义颜色和常量
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' 
INSTALL_DIR="/root/easytier"
CORE_BINARY="easytier-core"
WEB_BINARY="easytier-web-embed"
CORE_SERVICE="easytier.service"
WEB_SERVICE="easytier-web-embed.service"
GITHUB_API="https://api.github.com/repos/EasyTier/EasyTier/releases/latest"
DOWNLOAD_BASE_URL="https://docker.mk/https://github.com/EasyTier/EasyTier/releases/download/"

# -------------------------------
# 工具函数 (修复 A & B)
# -------------------------------
check_root() { [ "$EUID" -ne 0 ] && echo -e "${RED}请以 root 运行${NC}" && exit 1; }

get_version() {
    local VERSION=$(curl -fsSL "$GITHUB_API" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$VERSION" ] && VERSION=$(curl -fsSL -I "https://github.com/EasyTier/EasyTier/releases/latest" | grep -i "location:" | awk -F'/' '{print $NF}' | tr -d '\r')
    echo "$VERSION"
}

get_phy_iface() { ip route | grep default | awk '{print $5}' | head -1; }

# -------------------------------
# 核心部署逻辑
# -------------------------------
download_and_extract() {
    local VERSION="$1"
    local ARCH=$(uname -m)
    case $ARCH in x86_64) ARCH="x86_64" ;; aarch64) ARCH="aarch64" ;; *) ARCH="x86_64" ;; esac
    
    local download_url="${DOWNLOAD_BASE_URL}${VERSION}/easytier-linux-${ARCH}-${VERSION}.zip"
    echo -e "${YELLOW}正在下载 EasyTier ${VERSION}...${NC}"
    wget -q --show-progress -O "/tmp/easytier.zip" "$download_url"
    
    local temp_dir="/tmp/et_temp"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"
    unzip -q -o "/tmp/easytier.zip" -d "$temp_dir"

    mkdir -p "$INSTALL_DIR"
    mv -f $(find "$temp_dir" -name "$CORE_BINARY" -type f) "$INSTALL_DIR/"
    mv -f $(find "$temp_dir" -name "$WEB_BINARY" -type f) "$INSTALL_DIR/"
    chmod +x "${INSTALL_DIR}/${CORE_BINARY}" "${INSTALL_DIR}/${WEB_BINARY}"
    rm -rf "$temp_dir" "/tmp/easytier.zip"
}

# -------------------------------
# 服务创建：集成你提供的默认配置参数
# -------------------------------
create_web_service() {
    # 基于你提供的参数进行构建
    # --api-server-port: 前后端交互端口
    # --config-server-port: 节点连接端口
    local EXEC_CMD="${INSTALL_DIR}/${WEB_BINARY} \
        --api-server-port 11211 \
        --api-host \"http://127.0.0.1:11211\" \
        --config-server-port 22020 \
        --config-server-protocol udp"

    cat > "/etc/systemd/system/${WEB_SERVICE}" << EOF
[Unit]
Description=EasyTier Web Embed Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${EXEC_CMD}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$WEB_SERVICE"
    
    local IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    echo -e "${GREEN}Web 管理后台启动成功！${NC}"
    echo -e "Dashboard 地址: ${YELLOW}http://${IP}:11211${NC}"
    echo -e "配置下发协议: ${YELLOW}udp://服务器IP:22020${NC}"
}

create_core_service() {
    echo -e "\n${YELLOW}请选择 Core 运行模式:${NC}"
    echo "1) 手动模式 (命令行指定 IP/名称/密钥)"
    echo "2) 受管模式 (连接配置服务器)"
    read -p "选择 [1-2]: " MODE

    local EXEC_CMD=""
    if [ "$MODE" == "1" ]; then
        read -p "虚拟 IPv4 (如 10.144.144.1): " IPV4
        read -p "网络名称: " NET_NAME
        read -p "网络密钥: " NET_SECRET
        read -p "相邻节点 (可选): " PEERS
        EXEC_CMD="${INSTALL_DIR}/${CORE_BINARY} --ipv4 ${IPV4} --network-name ${NET_NAME} --network-secret ${NET_SECRET}"
        [ -n "$PEERS" ] && EXEC_CMD="${EXEC_CMD} --peers ${PEERS}"
    else
        read -p "主机名: " HNAME
        read -p "配置服务器 (udp://IP:22020/Network): " C_SERVER
        EXEC_CMD="${INSTALL_DIR}/${CORE_BINARY} --hostname ${HNAME} --config-server ${C_SERVER}"
    fi

    cat > "/etc/systemd/system/${CORE_SERVICE}" << EOF
[Unit]
Description=EasyTier Service
After=network.target

[Service]
Type=simple
ExecStart=${EXEC_CMD}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$CORE_SERVICE"
}

# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    while true; do
        echo -e "\n${GREEN}EasyTier 管理脚本 (正式默认版)${NC}"
        echo "1. 安装/配置 Core 节点"
        echo "2. 安装/启动 Web Embed (11211/22020)"
        echo "3. 开启网关转发 (NAT)"
        echo "4. 查看服务状态"
        echo "5. 卸载 EasyTier"
        echo "0. 退出"
        read -p "选择: " choice
        case $choice in
            1) check_root; download_and_extract $(get_version); create_core_service ;;
            2) check_root; download_and_extract $(get_version); create_web_service ;;
            3) check_root; PHY=$(get_phy_iface)
               echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-et.conf && sysctl -p /etc/sysctl.d/99-et.conf
               iptables -t nat -A POSTROUTING -o "$PHY" -j MASQUERADE
               iptables -A FORWARD -i "$PHY" -j ACCEPT
               echo "网关已开启 (网卡: $PHY)" ;;
            4) systemctl status "$CORE_SERVICE" "$WEB_SERVICE" | grep -E "Active|Loaded" ;;
            5) systemctl stop "$CORE_SERVICE" "$WEB_SERVICE"; rm -f /etc/systemd/system/easytier*; rm -rf "$INSTALL_DIR"; echo "已卸载" ;;
            0) exit 0 ;;
        esac
    done
}

main_menu
