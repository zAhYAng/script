#!/bin/bash

# -------------------------------
# 检查 unzip 是否安装
# -------------------------------
if ! command -v unzip &>/dev/null; then
    echo "未检测到 unzip，正在安装..."
    if [ -f /etc/debian_version ]; then
         apt-get update -y && apt-get install -y unzip
    elif [ -f /etc/redhat-release ]; then
         yum install -y unzip
    elif [ -f /etc/alpine-release ]; then
        apk add unzip
    else
        echo "无法自动安装 unzip，请手动安装后重试。"
        exit 1
    fi
else
    echo "unzip 已安装"
fi

# 获取CPU架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l) echo "armv7" ;;
        *) echo "unknown" ;;
    esac
}

# 从远程HTTP地址获取EasyTier版本号
get_version() {
    echo "正在检查最新版本..."
    EASYTIER_VERSION=$(curl -fsSL http://etsh2.442230.xyz/etver)
    if [ -z "$EASYTIER_VERSION" ]; then
        echo "警告: 无法从官方地址获取版本号，可能影响下载。"
        read -p "请手动输入要安装的 EasyTier 版本号 (例如 v2.4.5): " EASYTIER_VERSION
        if [ -z "$EASYTIER_VERSION" ]; then
            echo "错误: 版本号不能为空。"
            return 1
        fi
    fi
    echo "将安装 EasyTier 版本: $EASYTIER_VERSION"
    return 0
}

# 下载并解压EasyTier文件
download_and_extract() {
    local arch_name=$1
    local download_url=""
    local extracted_dir_name=""

    case $arch_name in
        x86_64)
            download_url="https://docker.mk/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-x86_64-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-x86_64"
            ;;
        aarch64)
            download_url="https://docker.mk/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-aarch64-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-aarch64"
            ;;
        armv7)
            download_url="https://docker.mk/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-armv7-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-armv7"
            ;;
        *)
            echo "错误: 不支持的CPU架构 $(uname -m)"
            return 1
            ;;
    esac

    echo "正在下载 EasyTier (${arch_name}) 到 /tmp/easytier.zip..."
    if ! wget -O /tmp/easytier.zip "$download_url"; then
        echo "错误: 下载EasyTier失败."
        return 1
    fi

    echo "正在解压文件到 /root/easytier/..."
    if ! unzip -o /tmp/easytier.zip -d /root/easytier/; then
        echo "错误: 解压EasyTier文件失败."
        rm -f /tmp/easytier.zip
        return 1
    fi

    if [ -d "/root/easytier/${extracted_dir_name}" ]; then
        echo "正在整理文件..."
        mv /root/easytier/"${extracted_dir_name}"/* /root/easytier/
        rmdir /root/easytier/"${extracted_dir_name}" 2>/dev/null
    fi

    rm -f /tmp/easytier.zip
    chmod +x /root/easytier/easytier-core
    chmod +x /root/easytier/easytier-cli
    echo "EasyTier文件下载并解压完成."
    return 0
}

# 安装流程
install_service() {
    echo "===== 开始安装 EasyTier ====="

    # 提示用户输入主机名（仅保留主机名）
    read -p "请输入您的主机名 (Hostname): " HOSTNAME
    if [ -z "$HOSTNAME" ]; then
        echo "错误: 主机名不能为空。"
        return 1
    fi

    # 直接要求输入自建配置服务器地址
    echo
    echo "请输入您的自建配置服务器地址。"
    read -p "配置服务器地址 (例如 udp://127.0.0.1:22020/admin): " CUSTOM_CONFIG_SERVER
    if [ -z "$CUSTOM_CONFIG_SERVER" ]; then
        echo "错误: 配置服务器地址不能为空。"
        return 1
    fi
    echo "将使用配置服务器: $CUSTOM_CONFIG_SERVER"

    # 1. 新建文件夹路径为 /root/easytier
    if [ -d "/root/easytier" ]; then
        echo "发现旧的安装目录，正在备份并清理..."
        mv /root/easytier /root/easytier.old.$(date +%Y%m%d%H%M%S)
    fi
    mkdir -p /root/easytier

    # 2. 根据架构下载并解压文件
    if ! download_and_extract "$ARCH"; then
        return 1
    fi

    # 3. 构建systemd服务命令（移除 -w $USERNAME 参数）
    EXEC_COMMAND="/root/easytier/easytier-core --hostname $HOSTNAME --config-server $CUSTOM_CONFIG_SERVER"

    # 4. 创建systemd服务文件
    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=$EXEC_COMMAND
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service

    # 5. 启动服务
    systemctl daemon-reload
    systemctl enable easytier
    systemctl restart easytier

    echo "===== EasyTier服务已安装并启动！ ====="
    echo "启动命令: $EXEC_COMMAND"
    echo "显示运行日志中，请按 Ctrl+C 取消输出"
    journalctl -f -u easytier.service
    return 0
}

# 修改配置流程
modify_config() {
    echo "===== 修改 EasyTier 配置 ====="

    # 检查服务是否存在
    if [ ! -f "/etc/systemd/system/easytier.service" ]; then
        echo "错误: 未检测到已安装的 EasyTier 服务。"
        return 1
    fi

    # 提示用户输入新的主机名（仅保留主机名）
    read -p "请输入新的主机名 (Hostname): " HOSTNAME
    if [ -z "$HOSTNAME" ]; then
        echo "错误: 主机名不能为空。"
        return 1
    fi

    # 修改自定义配置服务器
    CUSTOM_CONFIG_SERVER=""
    # 尝试从当前服务文件中读取已有的服务器地址
    EXISTING_SERVER=$(grep -oP "(?<=--config-server\s)[\'\"]?\K[^\'\"]+(?=[\'\"]?)" /etc/systemd/system/easytier.service)
    if [ -n "$EXISTING_SERVER" ]; then
        echo "当前配置的服务器: $EXISTING_SERVER"
        read -p "请输入新的配置服务器地址 (例如 udp://127.0.0.1:22020/admin): " CUSTOM_CONFIG_SERVER
        if [ -z "$CUSTOM_CONFIG_SERVER" ]; then
            echo "错误: 配置服务器地址不能为空。"
            return 1
        fi
    else
        read -p "请输入配置服务器地址 (例如 udp://127.0.0.1:22020/admin): " CUSTOM_CONFIG_SERVER
        if [ -z "$CUSTOM_CONFIG_SERVER" ]; then
            echo "错误: 配置服务器地址不能为空。"
            return 1
        fi
    fi

    # 构建新的启动命令（移除 -w $USERNAME 参数）
    EXEC_COMMAND="/root/easytier/easytier-core --hostname $HOSTNAME --config-server $CUSTOM_CONFIG_SERVER"

    # 更新服务文件
    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=$EXEC_COMMAND
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service

    # 重启服务
    systemctl daemon-reload
    systemctl restart easytier

    echo "===== EasyTier服务配置已更新并重启。 ====="
    echo "新启动命令: $EXEC_COMMAND"
    echo "查看日志:"
    journalctl -f -u easytier.service
    return 0
}

# 卸载流程
uninstall_service() {
    echo "===== 开始彻底卸载 EasyTier ====="
    echo "警告：此操作将删除以下所有内容，且无法恢复："
    echo "1. /root/easytier 安装目录及其所有文件"
    echo "2. /etc/systemd/system/easytier.service 服务文件"
    echo "3. 所有相关的系统服务配置"
    echo
    read -p "是否确定要继续? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "卸载已取消。"
        return 1
    fi

    echo "正在停止 easytier 服务..."
    systemctl stop easytier 2>/dev/null
    echo "正在禁用 easytier 服务..."
    systemctl disable easytier 2>/dev/null

    if [ -f "/etc/systemd/system/easytier.service" ]; then
        echo "正在删除服务文件 /etc/systemd/system/easytier.service..."
        rm -f "/etc/systemd/system/easytier.service"
    fi

    echo "正在重新加载 systemd 管理器配置..."
    systemctl daemon-reload

    if [ -d "/root/easytier" ]; then
        echo "正在删除安装目录 /root/easytier..."
        rm -rf "/root/easytier"
    fi

    BACKUP_DIRS=$(ls -d /root/easytier.old.* 2>/dev/null)
    if [ -n "$BACKUP_DIRS" ]; then
        read -p "是否同时删除旧的备份目录 (如 /root/easytier.old.xxxxxx)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "正在删除旧的备份目录..."
            rm -rf /root/easytier.old.*
        fi
    fi

    echo
    echo "===== EasyTier 已彻底卸载完毕。 ====="
    echo "唯一保留的文件是当前的脚本文件。"
    return 0
}

# 更新流程
update_service() {
    echo "===== 开始更新 EasyTier ====="

    if [ ! -f "/etc/systemd/system/easytier.service" ]; then
        echo "错误: 未检测到已安装的 EasyTier 服务，请先安装。"
        return 1
    fi

    # 保存当前启动命令（用于后续恢复配置）
    CURRENT_EXEC=$(grep -oP "(?<=ExecStart=).*" /etc/systemd/system/easytier.service)

    # 停止服务
    systemctl stop easytier 2>/dev/null

    # 备份并删除原来的程序文件目录
    if [ -d "/root/easytier" ]; then
        echo "正在备份当前安装目录..."
        mv /root/easytier /root/easytier.bak.$(date +%Y%m%d%H%M%S)
    fi

    # 新建文件夹并下载解压新文件
    mkdir -p /root/easytier
    if ! download_and_extract "$ARCH"; then
        echo "更新失败！您可以尝试从 /root/easytier.bak.$(date +%Y%m%d%H%M%S) 恢复。"
        return 1
    fi

    # 恢复原来的服务配置
    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=$CURRENT_EXEC
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service

    # 重新启动服务
    systemctl daemon-reload
    systemctl restart easytier

    echo "===== EasyTier服务已更新并重启。 ====="
    echo "启动命令: $CURRENT_EXEC"
    echo "查看日志:"
    journalctl -f -u easytier.service
    return 0
}

# -------------------------------
# 主程序 - 交互菜单
# -------------------------------
main() {
    # 预先获取版本和架构信息
    if ! get_version; then
        echo "版本检查失败，脚本可能无法正常工作。"
    fi
    ARCH=$(get_arch)
    echo "检测到CPU架构: $ARCH"
    echo "----------------------------------------"

    while true; do
        echo -e "\n===== EasyTier 交互式管理脚本 ====="
        echo "1) 安装 (Install) - 使用自建配置服务器"
        echo "2) 修改配置 (Modify Config)"
        echo "3) 卸载 (Uninstall) - 彻底清理"
        echo "4) 更新 (Update)"
        echo "0) 退出 (Exit)"
        read -p "请选择一个操作 [0-4]: " choice

        case $choice in
            1) install_service ;;
            2) modify_config ;;
            3) uninstall_service ;;
            4) update_service ;;
            0)
                echo "再见！"
                exit 0
                ;;
            *)
                echo "无效的选择，请输入 0-4 之间的数字。"
                ;;
        esac
        echo -e "\n----------------------------------------"
        read -p "按 Enter 键返回主菜单..."
    done
}

# 启动主程序
main