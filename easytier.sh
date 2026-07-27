#!/bin/bash

# -------------------------------
# 定义颜色和常量
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' 
INSTALL_DIR="/root/easytier"
CONFIG_FILE="${INSTALL_DIR}/config.toml"
CORE_BINARY="easytier-core"
WEB_BINARY="easytier-web-embed"
CORE_SERVICE="easytier.service"
WEB_SERVICE="easytier-web-embed.service"
GITHUB_API="https://api.github.com/repos/EasyTier/EasyTier/releases/latest"
DOWNLOAD_BASE_URL="https://github.com/EasyTier/EasyTier/releases/download/"

# -------------------------------
# 工具函数
# -------------------------------
check_root() { 
    [ "$EUID" -ne 0 ] && echo -e "${RED}错误：请以 root 权限运行此脚本！${NC}" && exit 1; 
}

check_dependencies() {
    local deps=("curl" "wget" "unzip" "iptables")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${YELLOW}提示：未检测到依赖 $cmd，正在尝试安装...${NC}"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -y && apt-get install -y "$cmd"
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "$cmd"
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y "$cmd"
            else
                echo -e "${RED}错误：无法自动安装 $cmd，请手动安装后重试。${NC}"
                exit 1
            fi
        fi
    done
}

get_version() {
    local VERSION=$(curl -fsSL "$GITHUB_API" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$VERSION" ] && VERSION=$(curl -fsSL -I "https://github.com/EasyTier/EasyTier/releases/latest" 2>/dev/null | grep -i "location:" | awk -F'/' '{print $NF}' | tr -d '\r')
    # 默认兜底版本
    [ -z "$VERSION" ] && VERSION="v2.6.4"
    echo "$VERSION"
}

get_phy_iface() { 
    ip route | grep default | awk '{print $5}' | head -1; 
}

# -------------------------------
# 核心部署逻辑（解压二进制程序，不覆盖配置文件）
# -------------------------------
download_and_extract() {
    local VERSION="$1"
    local ARCH=$(uname -m)
    case $ARCH in 
        x86_64) ARCH="x86_64" ;; 
        aarch64) ARCH="aarch64" ;; 
        *) ARCH="x86_64" ;; 
    esac
    
    # 规范化版本号格式（确保带有 v 前缀）
    [[ "$VERSION" != v* ]] && VERSION="v${VERSION}"

    local expected_zip="easytier-linux-${ARCH}-${VERSION}.zip"
    local target_zip="/tmp/easytier.zip"
    local local_found=""

    # 1. 优先匹配 /root 下精确架构与版本的压缩包
    if [ -f "/root/${expected_zip}" ]; then
        local_found="/root/${expected_zip}"
    # 2. 匹配 /root 下任意包含 easytier 的 zip 包
    elif ls /root/*easytier*.zip >/dev/null 2>&1; then
        local_found=$(ls /root/*easytier*.zip | head -n 1)
    fi

    if [ -n "$local_found" ]; then
        echo -e "${GREEN}【本地文件检测】发现本地安装包: ${local_found}，跳过 GitHub 下载。${NC}"
        cp "$local_found" "$target_zip"
    else
        local download_url="${DOWNLOAD_BASE_URL}${VERSION}/${expected_zip}"
        echo -e "${YELLOW}未在 /root 下找到匹配的本地包，正在下载 EasyTier ${VERSION}...${NC}"
        wget -q --show-progress -O "$target_zip" "$download_url"
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败！请检查网络或手动上传 ${expected_zip} 到 /root 目录。${NC}"
            exit 1
        fi
    fi
    
    # 解压并替换二进制程序
    local temp_dir="/tmp/et_temp"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"
    unzip -q -o "$target_zip" -d "$temp_dir"

    mkdir -p "$INSTALL_DIR"
    
    local found_core=$(find "$temp_dir" -name "$CORE_BINARY" -type f | head -n 1)
    local found_web=$(find "$temp_dir" -name "$WEB_BINARY" -type f | head -n 1)

    if [ -z "$found_core" ]; then
        echo -e "${RED}解压失败：压缩包内未找到 ${CORE_BINARY}，请检查包结构。${NC}"
        rm -rf "$temp_dir" "$target_zip"
        exit 1
    fi

    [ -n "$found_core" ] && mv -f "$found_core" "$INSTALL_DIR/"
    [ -n "$found_web" ] && mv -f "$found_web" "$INSTALL_DIR/"
    chmod +x "${INSTALL_DIR}/${CORE_BINARY}"
    [ -f "${INSTALL_DIR}/${WEB_BINARY}" ] && chmod +x "${INSTALL_DIR}/${WEB_BINARY}"
    
    rm -rf "$temp_dir" "$target_zip"
    echo -e "${GREEN}二进制程序更新/部署完成: ${INSTALL_DIR}${NC}"
}

# -------------------------------
# Core 节点服务与配置管理
# -------------------------------
create_core_service() {
    if [ ! -f "${INSTALL_DIR}/${CORE_BINARY}" ]; then
        echo -e "${RED}未能找到 ${CORE_BINARY}，正在提取程序...${NC}"
        download_and_extract $(get_version)
    fi

    echo -e "\n${YELLOW}请选择 Core 运行模式:${NC}"
    echo "1) 手动模式 (交互配置并生成 /root/easytier/config.toml)"
    echo "2) 受管模式 (连接配置服务器，不生成本地配置文件)"
    read -p "选择 [1-2]: " MODE

    local EXEC_CMD=""
    if [ "$MODE" == "1" ]; then
        read -p "虚拟 IPv4 (如 10.144.144.1): " IPV4
        read -p "网络名称: " NET_NAME
        read -p "网络密钥: " NET_SECRET
        read -p "相邻节点/Peers (可选, 如 tcp://1.2.3.4:11010): " PEERS

        # 优先通过官方指令生成 config.toml 文件
        local gen_cmd="${INSTALL_DIR}/${CORE_BINARY} --ipv4 ${IPV4} --network-name ${NET_NAME} --network-secret ${NET_SECRET}"
        [ -n "$PEERS" ] && gen_cmd="${gen_cmd} --peers ${PEERS}"
        
        echo -e "${YELLOW}正在创建独立配置文件 ${CONFIG_FILE}...${NC}"
        $gen_cmd -g "$CONFIG_FILE" >/dev/null 2>&1

        # 若内置生成失败则进行标准回退
        if [ $? -ne 0 ] || [ ! -f "$CONFIG_FILE" ]; then
            cat > "$CONFIG_FILE" << EOF
ipv4 = "${IPV4}"
network_name = "${NET_NAME}"
network_secret = "${NET_SECRET}"
EOF
            [ -n "$PEERS" ] && echo "peers = [ \"${PEERS}\" ]" >> "$CONFIG_FILE"
        fi
        
        echo -e "${GREEN}配置文件写入成功: ${CONFIG_FILE}${NC}"
        # 挂载配置文件的启动指令
        EXEC_CMD="${INSTALL_DIR}/${CORE_BINARY} -c ${CONFIG_FILE}"
    else
        read -p "主机名 (Hostname): " HNAME
        read -p "配置服务器 URL (如 udp://IP:22020/Network): " C_SERVER
        EXEC_CMD="${INSTALL_DIR}/${CORE_BINARY} --hostname ${HNAME} --config-server ${C_SERVER}"
    fi

    cat > "/etc/systemd/system/${CORE_SERVICE}" << EOF
[Unit]
Description=EasyTier Service
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
    systemctl daemon-reload && systemctl enable --now "$CORE_SERVICE"
    echo -e "${GREEN}Core 服务已启动！加载的二进制命令: ${EXEC_CMD}${NC}"
}

create_web_service() {
    if [ ! -f "${INSTALL_DIR}/${WEB_BINARY}" ]; then
        echo -e "${RED}未能找到 ${WEB_BINARY}，正在提取程序...${NC}"
        download_and_extract $(get_version)
    fi

    local EXEC_CMD="${INSTALL_DIR}/${WEB_BINARY} --api-server-port 11211 --api-host http://127.0.0.1:11211 --config-server-port 22020 --config-server-protocol udp"

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
    echo -e "\n${GREEN}Web 管理后台启动成功！${NC}"
    echo -e "Dashboard 地址: ${YELLOW}http://${IP}:11211${NC}"
    echo -e "配置下发协议:   ${YELLOW}udp://${IP}:22020${NC}"
}

# -------------------------------
# 软件升级逻辑（独立保护配置文件）
# -------------------------------
upgrade_easytier() {
    echo -e "\n${YELLOW}=== 开始升级 EasyTier 二进制核心 ===${NC}"
    
    local local_found=""
    if ls /root/*easytier*.zip >/dev/null 2>&1; then
        local_found=$(ls /root/*easytier*.zip | head -n 1)
    fi

    if [ -n "$local_found" ]; then
        echo -e "${GREEN}检测到本地升级包: ${local_found}${NC}"
        read -p "是否直接使用此本地包升级程序？[Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            download_and_extract "local"
        else
            local LATEST_VER=$(get_version)
            echo -e "从 GitHub 检查最新版本: ${GREEN}${LATEST_VER}${NC}"
            download_and_extract "$LATEST_VER"
        fi
    else
        local LATEST_VER=$(get_version)
        echo -e "GitHub 最新版本为: ${GREEN}${LATEST_VER}${NC}"
        read -p "是否确认下载升级？[Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            download_and_extract "$LATEST_VER"
        else
            echo -e "操作取消。"
            return
        fi
    fi
    
    # 替换程序后平滑重启服务
    if systemctl is-active --quiet "$CORE_SERVICE"; then
        echo -e "${YELLOW}正在重启 ${CORE_SERVICE}...${NC}"
        systemctl restart "$CORE_SERVICE"
    fi
    if systemctl is-active --quiet "$WEB_SERVICE"; then
        echo -e "${YELLOW}正在重启 ${WEB_SERVICE}...${NC}"
        systemctl restart "$WEB_SERVICE"
    fi
    
    echo -e "${GREEN}升级完成！${NC}"
    [ -f "$CONFIG_FILE" ] && echo -e "已有配置文件: ${YELLOW}${CONFIG_FILE}${NC} (已完好保留)"
}

enable_gateway() {
    local PHY=$(get_phy_iface)
    if [ -z "$PHY" ]; then
        echo -e "${RED}未能识别主物理网卡，请检查系统路由设置。${NC}"
        return
    fi
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-et.conf 
    sysctl -p /etc/sysctl.d/99-et.conf >/dev/null 2>&1
    
    iptables -t nat -A POSTROUTING -o "$PHY" -j MASQUERADE
    iptables -A FORWARD -i "$PHY" -j ACCEPT
    echo -e "${GREEN}网关 NAT 转发开启成功 (物理网卡: $PHY)${NC}"
}

show_status() {
    echo -e "\n${YELLOW}=== EasyTier 运行状态 ===${NC}"
    for svc in "$CORE_SERVICE" "$WEB_SERVICE"; do
        if systemctl is-active --quiet "$svc"; then
            echo -e "${svc}: ${GREEN}正在运行 (Running)${NC}"
        else
            echo -e "${svc}: ${RED}未运行 (Stopped / Not Installed)${NC}"
        fi
    done
    
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "配置文件路径: ${GREEN}${CONFIG_FILE}${NC}"
    else
        echo -e "配置文件路径: ${RED}暂未发现 ${CONFIG_FILE}${NC}"
    fi
}

uninstall_et() {
    read -p "确定要彻底卸载 EasyTier 及其所有配置吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl disable --now "$CORE_SERVICE" "$WEB_SERVICE" >/dev/null 2>&1
        rm -f "/etc/systemd/system/${CORE_SERVICE}" "/etc/systemd/system/${WEB_SERVICE}"
        systemctl daemon-reload
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}卸载完成。${NC}"
    fi
}

# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    check_root
    check_dependencies
    while true; do
        echo -e "\n${GREEN}===== EasyTier 管理脚本 =====${NC}"
        echo "1. 安装/配置 Core 节点 (生成 config.toml)"
        echo "2. 安装/启动 Web 控制台 (11211/22020)"
        echo "3. 检查与更新程序 (不影响 config.toml)"
        echo "4. 开启网关转发 (NAT)"
        echo "5. 查看服务状态"
        echo "6. 卸载 EasyTier"
        echo "0. 退出"
        read -p "请选择操作 [0-6]: " choice
        case $choice in
            1) download_and_extract $(get_version); create_core_service ;;
            2) download_and_extract $(get_version); create_web_service ;;
            3) upgrade_easytier ;;
            4) enable_gateway ;;
            5) show_status ;;
            6) uninstall_et ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入有误，请输入有效数字！${NC}" ;;
        esac
    done
}

main_menu
