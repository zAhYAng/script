#!/bin/bash
set -e  # 遇到错误立即退出

# 全局变量
SERVICE_NAME="migu-video"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
DEFAULT_WORK_DIR="/root/migu_video"
DEFAULT_LOG_FILE="/root/migu_video/migu_video.log"
NODE_PATH="/usr/bin/node"
NPM_PATH="/usr/bin/npm"
GITHUB_REPO="https://github.com/zAhYAng/migu_video.git"
BACKUP_DIR="/root/migu_video_backup"

# ====================== 工具函数 ======================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：该操作需要 root 权限，请用 sudo 运行脚本！"
        exit 1
    fi
}

# 确保日志文件存在
ensure_log_file() {
    local log_path=$1
    local log_dir=$(dirname "$log_path")

    echo "检查日志环境..."
    if [ ! -d "$log_dir" ]; then
        echo "创建日志目录: $log_dir"
        mkdir -p "$log_dir"
        chmod 755 "$log_dir"
    fi

    if [ ! -f "$log_path" ]; then
        echo "创建日志文件: $log_path"
        touch "$log_path"
        chmod 644 "$log_path"
    else
        echo "日志文件已存在：$log_path"
    fi
}

# 安装依赖并验证
install_node_deps() {
    local work_dir=$1
    echo "检测并安装 Node.js 依赖..."
    cd "$work_dir"
    
    # 安装核心依赖
    $NPM_PATH install axios --save > /dev/null 2>&1
    
    # 使用 CommonJS 语法验证
    if $NODE_PATH -e "require('axios')" > /dev/null 2>&1; then
        echo "axios 依赖检测成功"
    else
        echo "错误：axios 安装失败，请手动执行：cd $work_dir && npm install axios"
        exit 1
    fi
}

# 生成 Systemd 配置
create_systemd_service() {
    echo "生成 Systemd 服务配置文件..."
    cat > $SERVICE_FILE << EOF
[Unit]
Description=Migu Video Service (Node.js)
After=network.target

[Service]
User=root
WorkingDirectory=$WORK_DIR
Environment="muserId=$MUSER_ID"
Environment="mtoken=$MTOKEN"
Environment="mport=$MPORT"
Environment="mhost=$MHOST"
Environment="mrateType=$MRATE_TYPE"
ExecStart=$NODE_PATH app.js
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ====================== 核心逻辑：更新服务 (模式 2) ======================
update_service() {
    echo "======================================="
    echo "          开始更新咪咕视频服务           "
    echo "======================================="
    check_root
    
    read -p "请输入当前服务工作目录 (默认: $DEFAULT_WORK_DIR): " WORK_DIR
    WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}

    echo "1. 停止当前运行进程..."
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    pkill -f "node app.js" || true

    if [ -d "$WORK_DIR" ]; then
        echo "2. 备份当前代码..."
        mkdir -p "$BACKUP_DIR"
        tar -czf "$BACKUP_DIR/backup_$(date +%Y%m%d_%H%M%S).tar.gz" -C "$WORK_DIR" . || true
    fi

    echo "3. 获取最新代码..."
    TEMP_CLONE="/tmp/migu_clone_$(date +%s)"
    if git clone --depth=1 "$GITHUB_REPO" "$TEMP_CLONE"; then
        mkdir -p "$WORK_DIR"
        echo "同步文件中 (保留日志)..."
        # 清理旧代码文件，但保留 .log 文件
        find "$WORK_DIR" -maxdepth 1 ! -name '.' ! -name '*.log' -exec rm -rf {} +
        cp -r "$TEMP_CLONE"/. "$WORK_DIR/"
        rm -rf "$TEMP_CLONE"
    else
        echo "更新失败，请检查网络"; exit 1
    fi

    install_node_deps "$WORK_DIR"
    systemctl daemon-reload
    systemctl start $SERVICE_NAME
    echo "更新完成并已尝试启动服务。"
    exit 0
}

# ====================== 主菜单 ======================
echo "======================================="
echo "      咪咕视频 Node.js 服务管理脚本      "
echo "======================================="
echo "  1) 安装/配置并启动"
echo "  2) 更新服务 (安全模式)"
echo "  3) 卸载服务"
read -p "选择 (1/2/3, 默认1): " OPTION
OPTION=${OPTION:-1}

# 模式判断
if [ "$OPTION" == "2" ]; then update_service; fi
if [ "$OPTION" == "3" ]; then
    check_root
    echo "正在卸载服务..."
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true
    rm -f $SERVICE_FILE
    echo "卸载完成。"; exit 0
fi

# ====================== 模式 1：安装逻辑 ======================

# 第一步：创建目录并拉取代码
echo "步骤 1: 准备工作目录与代码..."
read -p "设置工作目录 (默认: $DEFAULT_WORK_DIR): " WORK_DIR
WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}

mkdir -p "$WORK_DIR"

if [ ! -f "$WORK_DIR/app.js" ]; then
    echo "正在拉取代码至 $WORK_DIR ..."
    # 如果目录里有碎文件导致无法 clone，进行清理（避开日志）
    if [ "$(ls -A $WORK_DIR)" ]; then
        find "$WORK_DIR" -maxdepth 1 ! -name '.' ! -name '*.log' -exec rm -rf {} +
    fi
    git clone --depth=1 "$GITHUB_REPO" "$WORK_DIR"
else
    echo "代码已存在，跳过克隆。"
fi

# 第二步：检查/创建日志文件
echo "步骤 2: 检查并创建日志文件..."
# 默认日志放在工作目录下
read -p "设置日志路径 (默认: $WORK_DIR/migu_video.log): " LOG_FILE
LOG_FILE=${LOG_FILE:-"$WORK_DIR/migu_video.log"}
ensure_log_file "$LOG_FILE"

# 第三步：输入业务配置参数
echo "步骤 3: 配置业务参数..."
read -p "muserId (1809453805): " MUSER_ID; MUSER_ID=${MUSER_ID:-1809453805}
read -p "mtoken (nlps0F2CDBC2A96ABD03DF3D): " MTOKEN; MTOKEN=${MTOKEN:-nlps0F2CDBC2A96ABD03DF3D}
read -p "mport (1234): " MPORT; MPORT=${MPORT:-1234}
read -p "mhost (http://10.10.1.4:1234): " MHOST; MHOST=${MHOST:-http://10.10.1.4:1234}
read -p "mrateType (4): " MRATE_TYPE; MRATE_TYPE=${MRATE_TYPE:-4}

# 第四步：环境准备与启动
echo "步骤 4: 正在启动服务..."
install_node_deps "$WORK_DIR"

# 停止可能存在的冲突进程
systemctl stop $SERVICE_NAME 2>/dev/null || true
pkill -f "node app.js" || true

create_systemd_service
systemctl enable $SERVICE_NAME --now

sleep 2
if systemctl is-active --quiet $SERVICE_NAME; then
    echo "======================================="
    echo "安装成功！服务正在运行。"
    echo "访问地址: http://$(echo "$MHOST" | awk -F'[:/]' '{print $4}'):$MPORT"
    echo "======================================="
else
    echo "启动可能存在问题，请检查日志: $LOG_FILE"
fi
