#!/bin/bash

# ===============================================================
# EasyTier 一键管理脚本 (最终增强版)
# 特性：配置解耦、路径统一、防火墙自动配置、实时状态看板
# ===============================================================

# -------------------------------
# 1. 定义颜色和常量
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 统一存放路径
INSTALL_DIR="/root/easytier"
CORE_BINARY="easytier-core"
WEB_BINARY="easytier-web-embed"
CORE_SERVICE="easytier.service"
WEB_SERVICE="easytier-web-embed.service"

# 配置文件路径
CORE_CONF="${INSTALL_DIR}/core.conf"
WEB_CONF="${INSTALL_DIR}/web.conf"

GITHUB_API="https://api.github.com/repos/EasyTier/EasyTier/releases/latest"
DOWNLOAD_BASE_URL="https://docker.mk/https://github.com/EasyTier/EasyTier/releases/download/"

# -------------------------------
# 2. 基础环境检查
# -------------------------------
ensure_dependency() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}检测到缺少必要组件: $cmd, 正在安装...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y "$pkg"
        elif command -v yum &> /dev/null; then
            yum install -y epel-release && yum install -y "$pkg"
        fi
    fi
}

check_root() { 
    [ "$EUID" -ne 0 ] && echo -e "${RED}请以 root 权限运行此脚本。${NC}" && exit 1 
}

# -------------------------------
# 3. 防火墙自动化逻辑
# -------------------------------
auto_fw_allow() {
    local tcp_port=$1
    local udp_port=$2
    local desc=$3
    echo -e "${YELLOW}正在配置防火墙放行 ${desc}...${NC}"

    # 检测 UFW
    if command -v ufw > /dev/null && ufw status | grep -q "Status: active"; then
        [ -n "$tcp_port" ] && ufw allow "$tcp_port"/tcp
        [ -n "$udp_port" ] && ufw allow "$udp_port"/udp
        ufw reload
    # 检测 Firewalld
    elif command -v firewall-cmd > /dev/null && systemctl is-active --quiet firewalld; then
        [ -n "$tcp_port" ] && firewall-cmd --permanent --add-port="$tcp_port"/tcp
        [ -n "$udp_port" ] && firewall-cmd --permanent --add-port="$udp_port"/udp
        firewall-cmd --reload
    # 兜底 Iptables
    else
        [ -n "$tcp_port" ] && iptables -I INPUT -p tcp --dport "$tcp_port" -j ACCEPT 2>/dev/null
        [ -n "$udp_port" ] && iptables -I INPUT -p udp --dport "$udp_port" -j ACCEPT 2>/dev/null
    fi
}

# -------------------------------
# 4. 下载逻辑
# -------------------------------
get_version() {
    ensure_dependency "curl"
    local VERSION=$(curl -fsSL "$GITHUB_API" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$VERSION" ] && VERSION="v2.1.0" # 备用硬编码版本
    echo "$VERSION"
}

download_and_extract() {
    if [ -f "${INSTALL_DIR}/${CORE_BINARY}" ] && [ -f "${INSTALL_DIR}/${WEB_BINARY}" ]; then
        echo -e "${GREEN}组件已存在于 ${INSTALL_DIR}，跳过下载。${NC}"
        return 0
    fi

    local VERSION="$1"
    ensure_dependency "wget"
    ensure_dependency "unzip"
    mkdir -p "$INSTALL_DIR"

    local ARCH=$(uname -m)
    case $ARCH in 
        x86_64) ARCH="x86_64" ;; 
        aarch64) ARCH="aarch64" ;; 
        *) ARCH="x86_64" ;; 
    esac
    
    local download_url="${DOWNLOAD_BASE_URL}${VERSION}/easytier-linux-${ARCH}-${VERSION}.zip"
    echo -e "${YELLOW}正在从 ${download_url} 下载...${NC}"
    wget -q --show-progress -O "/tmp/easytier.zip" "$download_url"
    
    local temp_dir="/tmp/et_temp"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"
    unzip -q -o "/tmp/easytier.zip" -d "$temp_dir"

    mv -f $(find "$temp_dir" -name "$CORE_BINARY" -type f) "$INSTALL_DIR/"
    mv -f $(find "$temp_dir" -name "$WEB_BINARY" -type f) "$INSTALL_DIR/"
    chmod +x "${INSTALL_DIR}/${CORE_BINARY}" "${INSTALL_DIR}/${WEB_BINARY}"
    
    rm -rf "$temp_dir" "/tmp/easytier.zip"
    echo -e "${GREEN}程序部署完成。${NC}"
}

# -------------------------------
# 5. 服务部署逻辑
# -------------------------------
create_web_service() {
    # 写入 Web 配置文件
    echo "ET_WEB_ARGS=\"--api-server-port 11211 --api-host http://127.0.0.1:11211 --config-server-port 22020 --config-server-protocol udp\"" > "$WEB_CONF"

    cat > "/etc/systemd/system/${WEB_SERVICE}" << EOF
[Unit]
Description=EasyTier Web Embed Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${WEB_CONF}
ExecStart=${INSTALL_DIR}/${WEB_BINARY} \$ET_WEB_ARGS
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$WEB_SERVICE"
    auto_fw_allow "11211" "22020" "EasyTier Web端及配置服务器"
    
    local IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}EasyTier Web 服务启动成功！${NC}"
    echo -e "管理页面: ${YELLOW}http://${IP}:11211${NC}"
    echo -e "配置服务器: ${YELLOW}udp://${IP}:22020${NC}"
}

create_core_service() {
    echo -e "\n${YELLOW}--- Core 节点配置 ---${NC}"
    echo "1) 手动模式 (自建网络)"
    echo "2) 受管模式 (连接配置服务器)"
    read -p "请选择模式 [1-2]: " MODE

    local ARGS=""
    if [ "$MODE" == "1" ]; then
        read -p "设定虚拟 IPv4: " IPV4
        read -p "设定网络名称: " NET_NAME
        read -p "设定网络密钥: " NET_SECRET
        read -p "通告子网 (可选, 如 192.168.1.0/24): " NETWORKS
        ARGS="--ipv4 ${IPV4} --network-name ${NET_NAME} --network-secret ${NET_SECRET}"
        [ -n "$NETWORKS" ] && ARGS="${ARGS} --networks ${NETWORKS}"
    else
        read -p "设定主机名: " HNAME
        read -p "配置服务器地址 (示例: udp://1.2.3.4:22020): " C_SERVER
        ARGS="--hostname ${HNAME} --config-server ${C_SERVER}"
    fi

    # 写入 Core 配置文件
    echo "ET_CORE_ARGS=\"${ARGS}\"" > "$CORE_CONF"

    cat > "/etc/systemd/system/${CORE_SERVICE}" << EOF
[Unit]
Description=EasyTier Core Service
After=network.target

[Service]
Type=simple
EnvironmentFile=${CORE_CONF}
ExecStart=${INSTALL_DIR}/${CORE_BINARY} \$ET_CORE_ARGS
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$CORE_SERVICE"
    auto_fw_allow "" "11010" "EasyTier P2P 通信"
    echo -e "${GREEN}Core 节点服务启动成功！${NC}"
}

# -------------------------------
# 6. 主菜单
# -------------------------------
main_menu() {
    while true; do
        echo -e "\n${CYAN}==============================================${NC}"
        echo -e "${CYAN}    EasyTier 管理脚本 (统一存放/解耦版)       ${NC}"
        echo -e "${CYAN}==============================================${NC}"
        echo "1. 安装/重配 Core 节点 (受管/手动)"
        echo "2. 安装/启动 Web 管理端 (作为配置中心)"
        echo "3. 开启网关转发 (NAT/IP Forward)"
        echo "4. 查看实时运行状态 (CLI 对等列表)"
        echo "5. 彻底卸载 EasyTier"
        echo "0. 退出"
        echo -e "${CYAN}==============================================${NC}"
        read -p "请输入选项 [0-5]: " choice
        case $choice in
            1) check_root; download_and_extract $(get_version); create_core_service ;;
            2) check_root; download_and_extract $(get_version); create_web_service ;;
            3)
                check_root
                echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-et.conf
                sysctl -p /etc/sysctl.d/99-et.conf
                local PHY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
                iptables -t nat -A POSTROUTING -o "$PHY_IF" -j MASQUERADE
                echo -e "${GREEN}网关转发已开启，出口网卡: $PHY_IF${NC}"
                ;;
            4)
                echo -e "\n${YELLOW}--- 节点实时状态看板 ---${NC}"
                if pgrep -x "$CORE_BINARY" > /dev/null; then
                    echo -e "${GREEN}[Core 运行中]${NC}"
                    echo -e "参数: $(grep 'ET_CORE_ARGS' $CORE_CONF 2>/dev/null || echo '未知')"
                    echo -e "\n邻居节点信息:"
                    $INSTALL_DIR/$CORE_BINARY cli peer
                    echo -e "\n虚拟路由表:"
                    $INSTALL_DIR/$CORE_BINARY cli route
                else
                    echo -e "${RED}[Core 服务未启动]${NC}"
                fi

                if pgrep -x "$WEB_BINARY" > /dev/null; then
                    echo -e "\n${GREEN}[Web 服务运行中]${NC}"
                fi
                ;;
            5)
                check_root
                echo -e "${RED}正在执行卸载...${NC}"
                systemctl stop "$CORE_SERVICE" "$WEB_SERVICE" 2>/dev/null
                systemctl disable "$CORE_SERVICE" "$WEB_SERVICE" 2>/dev/null
                rm -f /etc/systemd/system/easytier*
                systemctl daemon-reload
                rm -rf "$INSTALL_DIR"
                echo -e "${GREEN}卸载完成，所有文件已清理。${NC}"
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

# 启动脚本
main_menu
