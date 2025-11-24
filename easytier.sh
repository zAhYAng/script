#!/bin/bash

# -------------------------------
# 定义颜色和常量
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
INSTALL_DIR="/root/easytier"
CORE_BINARY="easytier-core"
WEB_BINARY="easytier-web-embed"
CORE_SERVICE="easytier.service"
WEB_SERVICE="easytier-web-embed.service"
VERSION_URL="http://etsh2.442230.xyz/etver"
DOWNLOAD_BASE_URL="https://docker.mk/https://github.com/EasyTier/EasyTier/releases/download/"

# -------------------------------
# 通用函数
# -------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请以 root 身份运行此脚本。${NC}"
        exit 1
    fi
}

check_unzip() {
    if ! command -v unzip &>/dev/null; then
        echo -e "${YELLOW}未检测到 unzip，正在尝试安装...${NC}"
        if [ -f /etc/debian_version ]; then
             apt-get update -y && apt-get install -y unzip
        elif [ -f /etc/redhat-release ]; then
             yum install -y unzip
        elif [ -f /etc/alpine-release ]; then
            apk add unzip
        else
            echo -e "${RED}无法自动安装 unzip，请手动安装后重试。${NC}"
            exit 1
        fi
        echo -e "${GREEN}unzip 安装成功。${NC}"
    fi
}

get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l) echo "armv7" ;;
        *) echo "unknown" ;;
    esac
}

get_version() {
    local VERSION=$(curl -fsSL "$VERSION_URL")
    echo "$VERSION"
}

# -------------------------------
# 核心下载函数 (修复了解压路径问题)
# -------------------------------
download_and_extract() {
    local VERSION="$1"
    local ARCH_NAME="$2"
    local download_url=""
    local temp_dir="/tmp/easytier_temp" # 临时目录，用于解压后查找文件

    # 构建正确的下载链接
    case $ARCH_NAME in
        x86_64)
            download_url="${DOWNLOAD_BASE_URL}${VERSION}/easytier-linux-x86_64-${VERSION}.zip"
            ;;
        aarch64)
            download_url="${DOWNLOAD_BASE_URL}${VERSION}/easytier-linux-aarch64-${VERSION}.zip"
            ;;
        armv7)
            download_url="${DOWNLOAD_BASE_URL}${VERSION}/easytier-linux-armv7-${VERSION}.zip"
            ;;
        *)
            echo -e "${RED}错误: 不支持的CPU架构 ${ARCH_NAME}${NC}"
            return 1
            ;;
    esac

    # 下载文件
    echo -e "\n${YELLOW}正在下载 EasyTier (${ARCH_NAME})...${NC}"
    echo -e "${YELLOW}下载地址: ${download_url}${NC}"
    wget -q -O "/tmp/easytier.zip" "$download_url"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 下载 EasyTier 失败。${NC}"
        rm -f "/tmp/easytier.zip"
        return 1
    fi

    # 清理旧的临时目录，创建新目录
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    # 解压到临时目录
    echo -e "${YELLOW}正在解压文件...${NC}"
    unzip -q -o "/tmp/easytier.zip" -d "$temp_dir"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 解压 EasyTier 文件失败。${NC}"
        rm -f "/tmp/easytier.zip"
        rm -rf "$temp_dir"
        return 1
    fi

    # 查找核心文件（处理压缩包内有二级目录的情况）
    echo -e "${YELLOW}正在查找核心文件...${NC}"
    local core_path=$(find "$temp_dir" -name "$CORE_BINARY" -type f | head -1)
    local web_path=$(find "$temp_dir" -name "$WEB_BINARY" -type f | head -1)

    if [ -z "$core_path" ] || [ -z "$web_path" ]; then
        echo -e "${RED}错误：解压后未找到核心文件（${CORE_BINARY} 或 ${WEB_BINARY}）！${NC}"
        echo -e "${YELLOW}压缩包内文件结构如下：${NC}"
        ls -lR "$temp_dir"
        rm -f "/tmp/easytier.zip"
        rm -rf "$temp_dir"
        return 1
    fi

    # 部署核心文件到安装目录
    echo -e "${YELLOW}正在部署核心文件到 ${INSTALL_DIR}...${NC}"
    rm -rf "${INSTALL_DIR:?}"/* # 清空安装目录
    mkdir -p "$INSTALL_DIR"
    mv -f "$core_path" "$INSTALL_DIR/"
    mv -f "$web_path" "$INSTALL_DIR/"

    # 添加执行权限
    chmod +x "${INSTALL_DIR}/${CORE_BINARY}" "${INSTALL_DIR}/${WEB_BINARY}"

    # 清理临时文件
    rm -f "/tmp/easytier.zip"
    rm -rf "$temp_dir"

    echo -e "${GREEN}整合包下载解压完成！核心文件已部署到 ${INSTALL_DIR}${NC}"
    return 0
}

# -------------------------------
# 服务创建函数
# -------------------------------
create_core_service() {
    local HOSTNAME="$1"
    local CUSTOM_CONFIG_SERVER="$2"
    local EXEC_COMMAND="${INSTALL_DIR}/${CORE_BINARY} --hostname ${HOSTNAME} --config-server ${CUSTOM_CONFIG_SERVER}"

    echo -e "\n${YELLOW}正在创建 ${CORE_SERVICE} 服务文件...${NC}"
    cat > "/etc/systemd/system/${CORE_SERVICE}" << EOF
[Unit]
Description=EasyTier Core Service
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
ExecStart=${EXEC_COMMAND}
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$CORE_SERVICE"
    systemctl restart "$CORE_SERVICE"
    echo -e "${GREEN}${CORE_SERVICE} 服务已启动。${NC}"
}

create_web_service() {
    local EXEC_COMMAND="${INSTALL_DIR}/${WEB_BINARY}"

    echo -e "\n${YELLOW}正在创建 ${WEB_SERVICE} 服务文件...${NC}"
    cat > "/etc/systemd/system/${WEB_SERVICE}" << EOF
[Unit]
Description=easytier-web-embed Service
After=network.target

[Service]
Type=simple
ExecStart=${EXEC_COMMAND}
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$WEB_SERVICE"
    systemctl restart "$WEB_SERVICE"
    echo -e "${GREEN}${WEB_SERVICE} 服务已启动。${NC}"
}

# -------------------------------
# 功能函数
# -------------------------------
install_core() {
    check_root
    check_unzip

    echo -e "${YELLOW}正在从 ${VERSION_URL} 获取版本号...${NC}"
    local VERSION=$(get_version)
    if [ -z "$VERSION" ]; then
        echo -e "${RED}错误: 无法从 ${VERSION_URL} 获取 EasyTier 版本号。${NC}"
        return 1
    fi
    echo -e "${GREEN}检测到 EasyTier 版本: $VERSION${NC}"

    local ARCH=$(get_arch)
    if [ "$ARCH" = "unknown" ]; then
        echo -e "${RED}错误：无法识别的 CPU 架构: $(uname -m)${NC}"
        return 1
    fi

    if ! download_and_extract "$VERSION" "$ARCH"; then
        echo -e "${RED}整合包下载解压失败，安装终止。${NC}"
        return 1
    fi

    read -p "请输入您的主机名 (Hostname): " HOSTNAME
    if [ -z "$HOSTNAME" ]; then
        echo -e "${RED}错误：主机名不能为空。${NC}"
        return 1
    fi

    echo -e "\n请输入您的自建配置服务器地址。"
    read -p "配置服务器地址 (例如 udp://et.example.com/admin): " CUSTOM_CONFIG_SERVER
    if [ -z "$CUSTOM_CONFIG_SERVER" ]; then
        echo -e "${RED}错误：配置服务器地址不能为空。${NC}"
        return 1
    fi

    create_core_service "$HOSTNAME" "$CUSTOM_CONFIG_SERVER"

    echo -e "\n${GREEN}==================== Core 安装完成 ====================${NC}"
    echo -e "${GREEN}服务名称:${NC} ${CORE_SERVICE}"
    echo -e "${GREEN}启动命令:${NC} ${INSTALL_DIR}/${CORE_BINARY} --hostname ${HOSTNAME} --config-server ${CUSTOM_CONFIG_SERVER}"
    echo -e "${GREEN}服务状态:${NC}"
    systemctl is-active --quiet "$CORE_SERVICE" && echo -e "  ${GREEN}正在运行${NC}" || echo -e "  ${RED}未运行${NC}"
    echo -e "${YELLOW}查看日志:${NC} journalctl -u ${CORE_SERVICE} -f"
    echo -e "${GREEN}=====================================================${NC}"
}

install_web() {
    check_root
    check_unzip

    if [ ! -d "$INSTALL_DIR" ] || [ ! -f "${INSTALL_DIR}/${CORE_BINARY}" ]; then
        echo -e "${YELLOW}未检测到 EasyTier 整合包，将自动下载安装。${NC}"
        echo -e "${YELLOW}正在从 ${VERSION_URL} 获取版本号...${NC}"
        local VERSION=$(get_version)
        if [ -z "$VERSION" ]; then
            echo -e "${RED}错误: 无法从 ${VERSION_URL} 获取 EasyTier 版本号。${NC}"
            return 1
        fi
        echo -e "${GREEN}检测到 EasyTier 版本: $VERSION${NC}"

        local ARCH=$(get_arch)
        if [ "$ARCH" = "unknown" ]; then
            echo -e "${RED}错误：无法识别的 CPU 架构: $(uname -m)${NC}"
            return 1
        fi

        if ! download_and_extract "$VERSION" "$ARCH"; then
            echo -e "${RED}整合包下载解压失败，无法安装 Web Embed。${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}检测到已存在整合包，直接创建 Web 服务。${NC}"
    fi

    create_web_service

    echo -e "\n${GREEN}==================== Web Embed 安装完成 ====================${NC}"
    echo -e "${GREEN}服务名称:${NC} ${WEB_SERVICE}"
    echo -e "${GREEN}安装路径:${NC} ${INSTALL_DIR}/${WEB_BINARY}"
    echo -e "${GREEN}服务状态:${NC}"
    systemctl is-active --quiet "$WEB_SERVICE" && echo -e "  ${GREEN}正在运行${NC}" || echo -e "  ${RED}未运行${NC}"
    echo -e "${YELLOW}查看日志:${NC} journalctl -u ${WEB_SERVICE} -f"
    echo -e "${GREEN}==========================================================${NC}"
}

modify_config() {
    check_root
    if [ ! -f "/etc/systemd/system/${CORE_SERVICE}" ]; then
        echo -e "${RED}错误：未检测到 Core 服务，请先安装。${NC}"
        return 1
    fi

    read -p "请输入新的主机名 (Hostname): " HOSTNAME
    if [ -z "$HOSTNAME" ]; then
        echo -e "${RED}错误：主机名不能为空。${NC}"
        return 1
    fi

    echo -e "\n请输入新的自建配置服务器地址。"
    read -p "配置服务器地址 (例如 udp://et.example.com/admin): " CUSTOM_CONFIG_SERVER
    if [ -z "$CUSTOM_CONFIG_SERVER" ]; then
        echo -e "${RED}错误：配置服务器地址不能为空。${NC}"
        return 1
    fi

    local EXEC_COMMAND="${INSTALL_DIR}/${CORE_BINARY} --hostname ${HOSTNAME} --config-server ${CUSTOM_CONFIG_SERVER}"
    sed -i "s|^ExecStart=.*|ExecStart=${EXEC_COMMAND}|" "/etc/systemd/system/${CORE_SERVICE}"

    systemctl daemon-reload
    systemctl restart "$CORE_SERVICE"
    echo -e "\n${GREEN}配置修改完成！${NC}"
    echo -e "${GREEN}新启动命令:${NC} ${EXEC_COMMAND}"
}

update_core() {
    check_root
    if [ ! -f "/etc/systemd/system/${CORE_SERVICE}" ]; then
        echo -e "${RED}错误：未检测到 Core 服务，请先安装。${NC}"
        return 1
    fi

    local CURRENT_EXEC=$(grep -oP "(?<=ExecStart=).*" "/etc/systemd/system/${CORE_SERVICE}")
    echo -e "${YELLOW}正在从 ${VERSION_URL} 获取最新版本号...${NC}"
    local VERSION=$(get_version)
    if [ -z "$VERSION" ]; then
        echo -e "${RED}错误: 无法从 ${VERSION_URL} 获取 EasyTier 版本号。${NC}"
        return 1
    fi
    echo -e "${GREEN}检测到最新 EasyTier 版本: $VERSION${NC}"

    read -p "确定要更新到版本 ${VERSION} 吗? (Y/n): " CONFIRM
    if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
        echo "更新已取消。"
        return 0
    fi

    local ARCH=$(get_arch)
    cp -n "${INSTALL_DIR}/${CORE_BINARY}" "${INSTALL_DIR}/${CORE_BINARY}.bak"
    cp -n "${INSTALL_DIR}/${WEB_BINARY}" "${INSTALL_DIR}/${WEB_BINARY}.bak"

    if ! download_and_extract "$VERSION" "$ARCH"; then
        echo -e "${YELLOW}更新失败，正在恢复备份...${NC}"
        mv -f "${INSTALL_DIR}/${CORE_BINARY}.bak" "${INSTALL_DIR}/${CORE_BINARY}"
        mv -f "${INSTALL_DIR}/${WEB_BINARY}.bak" "${INSTALL_DIR}/${WEB_BINARY}"
        echo -e "${RED}恢复完成，请检查网络后重试。${NC}"
        return 1
    fi

    systemctl restart "$CORE_SERVICE"
    echo -e "\n${GREEN}Core 更新完成！${NC}"
    echo -e "${GREEN}当前启动命令:${NC} ${CURRENT_EXEC}"
    echo -e "${GREEN}服务状态:${NC}"
    systemctl is-active --quiet "$CORE_SERVICE" && echo -e "  ${GREEN}正在运行${NC}" || echo -e "  ${RED}未运行${NC}"
}

uninstall_all() {
    check_root
    echo -e "${YELLOW}警告：此操作将删除所有 EasyTier 组件！${NC}"
    read -p "确定要继续卸载吗? (y/N): " -n 1 -r
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "卸载已取消。"
        return 1
    fi

    systemctl stop "$CORE_SERVICE" "$WEB_SERVICE" 2>/dev/null
    systemctl disable "$CORE_SERVICE" "$WEB_SERVICE" 2>/dev/null
    rm -f "/etc/systemd/system/${CORE_SERVICE}" "/etc/systemd/system/${WEB_SERVICE}"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"

    echo -e "\n${GREEN}EasyTier 已彻底卸载完毕。${NC}"
}

check_status() {
    echo -e "${YELLOW}==================== EasyTier 服务状态 ====================${NC}"
    
    echo -e "\n${GREEN}1. ${CORE_SERVICE}:${NC}"
    if [ -f "/etc/systemd/system/${CORE_SERVICE}" ]; then
        systemctl is-active --quiet "$CORE_SERVICE" && echo -e "   状态: ${GREEN}正在运行${NC}" || echo -e "   状态: ${RED}未运行${NC}"
        echo -e "   开机自启: $(systemctl is-enabled --quiet "$CORE_SERVICE" && echo -e "${GREEN}已启用${NC}" || echo -e "${RED}已禁用${NC}")"
    else
        echo -e "   状态: ${RED}未安装${NC}"
    fi

    echo -e "\n${GREEN}2. ${WEB_SERVICE}:${NC}"
    if [ -f "/etc/systemd/system/${WEB_SERVICE}" ]; then
        systemctl is-active --quiet "$WEB_SERVICE" && echo -e "   状态: ${GREEN}正在运行${NC}" || echo -e "   状态: ${RED}未运行${NC}"
        echo -e "   开机自启: $(systemctl is-enabled --quiet "$WEB_SERVICE" && echo -e "${GREEN}已启用${NC}" || echo -e "${RED}已禁用${NC}")"
    else
        echo -e "   状态: ${RED}未安装${NC}"
    fi
    
    echo -e "\n${GREEN}3. 网关配置:${NC}"
    IP_FORWARD_STATUS=$(sysctl net.ipv4.ip_forward | awk '{print $3}')
    echo -e "   IPv4 转发: $( [ "$IP_FORWARD_STATUS" -eq 1 ] && echo -e "${GREEN}开启${NC}" || echo -e "${RED}关闭${NC}")"
    echo -e "${YELLOW}=========================================================${NC}"
}

# -------------------------------
# 网关配置函数 (根据你的要求修正)
# -------------------------------
configure_gateway() {
    check_root
    if [ ! -f "/etc/systemd/system/${CORE_SERVICE}" ]; then
        echo -e "${RED}错误：请先安装 EasyTier Core 服务，再配置网关。${NC}"
        return 1
    fi

    echo -e "\n${YELLOW}--- 开始配置网关功能 ---${NC}"
    echo -e "${YELLOW}1. 正在开启 IPv4 转发...${NC}"
    if grep -q "net.ipv4.ip_forward" /etc/sysctl.conf; then
        sed -i "s/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/" /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi
    sysctl -p
    echo -e "${GREEN}   IPv4 转发已开启。${NC}"

    echo -e "${YELLOW}2. 正在配置 iptables 规则...${NC}"
    
    # 允许从 eth0 转发
    iptables -I FORWARD -i eth0 -j ACCEPT
    echo -e "   iptables -I FORWARD -i eth0 -j ACCEPT ${GREEN}[已添加]${NC}"

    # 允许转发到 eth0
    iptables -I FORWARD -o eth0 -j ACCEPT
    echo -e "   iptables -I FORWARD -o eth0 -j ACCEPT ${GREEN}[已添加]${NC}"

    # 为 eth0 出口流量配置 NAT
    iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE
    echo -e "   iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE ${GREEN}[已添加]${NC}"

    # 允许从 tun0 转发
    iptables -I FORWARD -i tun0 -j ACCEPT
    echo -e "   iptables -I FORWARD -i tun0 -j ACCEPT ${GREEN}[已添加]${NC}"

    # 允许转发到 tun0
    iptables -I FORWARD -o tun0 -j ACCEPT
    echo -e "   iptables -I FORWARD -o tun0 -j ACCEPT ${GREEN}[已添加]${NC}"

    # 为 tun0 出口流量配置 NAT
    iptables -t nat -I POSTROUTING -o tun0 -j MASQUERADE
    echo -e "   iptables -t nat -I POSTROUTING -o tun0 -j MASQUERADE ${GREEN}[已添加]${NC}"

    echo -e "${GREEN}--- 网关功能配置完成 ---${NC}"
}

# -------------------------------
# 移除网关NAT配置函数 (根据你的要求修正)
# -------------------------------
remove_gateway_nat() {
    check_root

    echo -e "\n${YELLOW}--- 开始移除网关NAT配置 ---${NC}"
    
    # 1. 尝试关闭 IPv4 转发
    echo -e "${YELLOW}1. 正在关闭 IPv4 转发...${NC}"
    if grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        sed -i "s/^net.ipv4.ip_forward = 1.*/net.ipv4.ip_forward = 0/" /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}   IPv4 转发已关闭。${NC}"
    else
        echo -e "${YELLOW}   IPv4 转发未开启，跳过。${NC}"
    fi

    # 2. 尝试删除 iptables 规则
    echo -e "${YELLOW}2. 正在删除 iptables 规则...${NC}"
    
    # 删除 FORWARD 规则
    iptables -D FORWARD -i eth0 -j ACCEPT 2>/dev/null && echo -e "   iptables -D FORWARD -i eth0 -j ACCEPT ${GREEN}[已删除]${NC}" || echo -e "   未找到 FORWARD -i eth0 规则，跳过。${NC}"
    iptables -D FORWARD -o eth0 -j ACCEPT 2>/dev/null && echo -e "   iptables -D FORWARD -o eth0 -j ACCEPT ${GREEN}[已删除]${NC}" || echo -e "   未找到 FORWARD -o eth0 规则，跳过。${NC}"
    iptables -D FORWARD -i tun0 -j ACCEPT 2>/dev/null && echo -e "   iptables -D FORWARD -i tun0 -j ACCEPT ${GREEN}[已删除]${NC}" || echo -e "   未找到 FORWARD -i tun0 规则，跳过。${NC}"
    iptables -D FORWARD -o tun0 -j ACCEPT 2>/dev/null && echo -e "   iptables -D FORWARD -o tun0 -j ACCEPT ${GREEN}[已删除]${NC}" || echo -e "   未找到 FORWARD -o tun0 规则，跳过。${NC}"

    # 删除 NAT 规则
    iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null && echo -e "   iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE ${GREEN}[已删除]${NC}" || echo -e "   未找到 POSTROUTING -o eth0 规则，跳过。${NC}"
    iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null && echo -e "   iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE ${GREEN}[已删除]${NC}" || echo -e "   未找到 POSTROUTING -o tun0 规则，跳过。${NC}"

    echo -e "${GREEN}--- 网关NAT配置移除完成 ---${NC}"
}


# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    while true; do
        clear
        echo -e "${YELLOW}=====================================================${NC}"
        echo -e "${GREEN}              EasyTier 一体化管理脚本             ${NC}"
        echo -e "${YELLOW}=====================================================${NC}"
        echo -e "${GREEN}1. 安装 EasyTier Core (核心服务)${NC}"
        echo -e "${GREEN}2. 安装 EasyTier Web Embed (网页嵌入服务)${NC}"
        echo -e "${YELLOW}-----------------------------------------------------${NC}"
        echo -e "${GREEN}3. 修改 EasyTier Core 配置${NC}"
        echo -e "${GREEN}4. 更新 EasyTier Core (更新整合包)${NC}"
        echo -e "${YELLOW}-----------------------------------------------------${NC}"
        echo -e "${GREEN}5. 配置网关功能${NC}"
        echo -e "${RED}6. 移除网关NAT配置${NC}"
        echo -e "${YELLOW}-----------------------------------------------------${NC}"
        echo -e "${RED}7. 彻底卸载所有 EasyTier 组件${NC}"
        echo -e "${YELLOW}-----------------------------------------------------${NC}"
        echo -e "${GREEN}8. 查看服务状态${NC}"
        echo -e "${RED}0. 退出${NC}"
        echo -e "${YELLOW}=====================================================${NC}"
        read -p "请选择一个操作 [0-8]: " choice

        case $choice in
            1) install_core; read -p "按 Enter 键返回主菜单..." ;;
            2) install_web; read -p "按 Enter 键返回主菜单..." ;;
            3) modify_config; read -p "按 Enter 键返回主菜单..." ;;
            4) update_core; read -p "按 Enter 键返回主菜单..." ;;
            5) configure_gateway; read -p "按 Enter 键返回主菜单..." ;;
            6) remove_gateway_nat; read -p "按 Enter 键返回主菜单..." ;;
            7) uninstall_all; read -p "按 Enter 键返回主菜单..." ;;
            8) check_status; read -p "按 Enter 键返回主菜单..." ;;
            0) echo "再见！"; exit 0 ;;
            *) echo -e "${RED}无效的选择，请输入 0-8 之间的数字。${NC}"; read -p "按 Enter 键返回主菜单..." ;;
        esac
    done
}

# 启动主菜单
main_menu