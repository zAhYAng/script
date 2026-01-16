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
# 动态依赖检查函数
# -------------------------------
ensure_dependency() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}检测到缺少必要组件: $cmd, 正在尝试自动安装 $pkg...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y "$pkg"
        elif command -v yum &> /dev/null; then
            yum install -y epel-release && yum install -y "$pkg"
        else
            echo -e "${RED}无法自动安装 $pkg，请手动安装后重新运行脚本。${NC}"
            exit 1
        fi
    fi
}

# -------------------------------
# 工具函数
# -------------------------------
check_root() { 
    [ "$EUID" -ne 0 ] && echo -e "${RED}请以 root 权限运行此脚本。${NC}" && exit 1 
}

get_version() {
    ensure_dependency "curl"
    local VERSION=$(curl -fsSL "$GITHUB_API" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$VERSION" ] && VERSION=$(curl -fsSL -I "https://github.com/EasyTier/EasyTier/releases/latest" | grep -i "location:" | awk -F'/' '{print $NF}' | tr -d '\r')
    echo "$VERSION"
}

get_phy_iface() { 
    ensure_dependency "ip" "iproute2"
    ip route | grep default | awk '{print $5}' | head -1
}

# -------------------------------
# 核心下载与检测逻辑 (已优化)
# -------------------------------
download_and_extract() {
    # 1. 检查本地是否已经安装过且文件完整
    if [ -f "${INSTALL_DIR}/${CORE_BINARY}" ] && [ -f "${INSTALL_DIR}/${WEB_BINARY}" ]; then
        echo -e "${GREEN}检测到本地已存在 EasyTier 组件，跳过下载。${NC}"
        chmod +x "${INSTALL_DIR}/${CORE_BINARY}" "${INSTALL_DIR}/${WEB_BINARY}"
        return 0
    fi

    # 2. 如果文件缺失，则执行下载
    local VERSION="$1"
    ensure_dependency "wget"
    ensure_dependency "unzip"

    local ARCH=$(uname -m)
    case $ARCH in 
        x86_64) ARCH="x86_64" ;; 
        aarch64) ARCH="aarch64" ;; 
        *) ARCH="x86_64" ;; 
    esac
    
    local download_url="${DOWNLOAD_BASE_URL}${VERSION}/easytier-linux-${ARCH}-${VERSION}.zip"
    echo -e "${YELLOW}本地组件不完整，正在下载 EasyTier ${VERSION}...${NC}"
    wget -q --show-progress -O "/tmp/easytier.zip" "$download_url"
    
    local temp_dir="/tmp/et_temp"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"
    unzip -q -o "/tmp/easytier.zip" -d "$temp_dir"

    mkdir -p "$INSTALL_DIR"
    mv -f $(find "$temp_dir" -name "$CORE_BINARY" -type f) "$INSTALL_DIR/"
    mv -f $(find "$temp_dir" -name "$WEB_BINARY" -type f) "$INSTALL_DIR/"
    chmod +x "${INSTALL_DIR}/${CORE_BINARY}" "${INSTALL_DIR}/${WEB_BINARY}"
    
    rm -rf "$temp_dir" "/tmp/easytier.zip"
    echo -e "${GREEN}程序文件下载并部署完成。${NC}"
}

# -------------------------------
# 服务创建逻辑
# -------------------------------
create_web_service() {
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
    
    ensure_dependency "curl"
    local IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}EasyTier Web 服务已启动！${NC}"
    echo -e "管理后台: ${YELLOW}http://${IP}:11211${NC}"
    echo -e "配置服务器: ${YELLOW}udp://${IP}:22020${NC}"
}

create_core_service() {
    echo -e "\n${YELLOW}--- Core 节点配置 ---${NC}"
    echo "1) 手动模式 (指定虚拟IP/网络名/密钥)"
    echo "2) 受管模式 (连接到 Web 版的配置服务器)"
    read -p "请选择模式 [1-2]: " MODE

    local EXEC_CMD=""
    if [ "$MODE" == "1" ]; then
        read -p "设定虚拟 IPv4: " IPV4
        read -p "设定网络名称: " NET_NAME
        read -p "设定网络密钥: " NET_SECRET
        read -p "相邻节点 (可选): " PEERS
        EXEC_CMD="${INSTALL_DIR}/${CORE_BINARY} --ipv4 ${IPV4} --network-name ${NET_NAME} --network-secret ${NET_SECRET}"
        [ -n "$PEERS" ] && EXEC_CMD="${EXEC_CMD} --peers ${PEERS}"
    else
        read -p "设定主机名: " HNAME
        read -p "输入配置服务器地址 (udp://IP:22020/Net): " C_SERVER
        EXEC_CMD="${INSTALL_DIR}/${CORE_BINARY} --hostname ${HNAME} --config-server ${C_SERVER}"
    fi

    cat > "/etc/systemd/system/${CORE_SERVICE}" << EOF
[Unit]
Description=EasyTier Core Service
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
    echo -e "${GREEN}Core 节点服务已启动！${NC}"
}

# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    while true; do
        echo -e "\n${GREEN}======= EasyTier 管理脚本 (本地优先) =======${NC}"
        echo "1. 安装/配置 Core 节点"
        echo "2. 安装/启动 Web 管理端"
        echo "3. 开启网关转发 (NAT)"
        echo "4. 查看当前运行状态"
        echo "5. 卸载 EasyTier"
        echo "0. 退出"
        echo -e "${GREEN}============================================${NC}"
        read -p "请输入选项 [0-5]: " choice
        case $choice in
            1) check_root; download_and_extract $(get_version); create_core_service ;;
            2) check_root; download_and_extract $(get_version); create_web_service ;;
            3)
                check_root
                ensure_dependency "iptables"
                PHY_IF=$(get_phy_iface)
                echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-et.conf
                sysctl -p /etc/sysctl.d/99-et.conf
                iptables -t nat -A POSTROUTING -o "$PHY_IF" -j MASQUERADE
                iptables -A FORWARD -i "$PHY_IF" -j ACCEPT
                echo -e "${GREEN}网关转发已开启，出口网卡: $PHY_IF${NC}"
                ;;
            4)
                echo -e "\n${YELLOW}服务状态:${NC}"
                systemctl status "$CORE_SERVICE" "$WEB_SERVICE" 2>/dev/null | grep -E "Active|Loaded" || echo "未检测到服务"
                ;;
            5)
                check_root
                systemctl stop "$CORE_SERVICE" "$WEB_SERVICE" 2>/dev/null
                systemctl disable "$CORE_SERVICE" "$WEB_SERVICE" 2>/dev/null
                rm -f /etc/systemd/system/easytier*
                systemctl daemon-reload
                rm -rf "$INSTALL_DIR"
                echo -e "${RED}EasyTier 已彻底卸载。${NC}"
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

main_menu
