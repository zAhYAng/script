#!/bin/bash
set -e  # 遇到错误立即退出

# 全局变量
SERVICE_NAME="migu-video"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
DEFAULT_WORK_DIR="/root/migu_video"
DEFAULT_LOG_FILE="/root/migu_video/migu_video.log"
NODE_PATH="/usr/bin/node"
NPM_PATH="/usr/bin/npm"
GITHUB_REPO="https://hk.gh-proxy.org/https://github.com/zAhYAng/migu_video.git"
BACKUP_DIR="/root/migu_video_backup"

# ====================== 工具函数 ======================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：该操作需要 root 权限，请用 sudo 运行脚本！"
        exit 1
    fi
}

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
    fi
}

install_node_deps() {
    local work_dir=$1
    echo "检测并安装 Node.js 依赖..."
    cd "$work_dir"
    $NPM_PATH install axios --save > /dev/null 2>&1
    if $NODE_PATH -e "require('axios')" > /dev/null 2>&1; then
        echo "axios 依赖检测成功"
    else
        echo "错误：axios 安装失败，请手动执行：cd $work_dir && npm install axios"
        exit 1
    fi
}

# 生成 Systemd 配置 (集成新增的分类控制变量)
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
Environment="menableHDR=$MENABLE_HDR"
Environment="menableH265=$MENABLE_H265"
Environment="mupdateInterval=$MUPDATE_INTERVAL"
Environment="mignoreCategory=$MIGNORE_CATEGORY"
Environment="mmergeTVCategory=$MMERGE_TV_CATEGORY"
Environment="mcustomMergeCategory=$MCUSTOM_MERGE_CATEGORY"
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

# ====================== 核心逻辑：更新服务 ======================
update_service() {
    echo "======================================="
    echo "          开始更新咪咕视频服务           "
    echo "======================================="
    check_root
    read -p "请输入当前服务工作目录 (默认: $DEFAULT_WORK_DIR): " WORK_DIR
    WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}

    systemctl stop $SERVICE_NAME 2>/dev/null || true
    pkill -f "node app.js" || true

    if [ -d "$WORK_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        tar -czf "$BACKUP_DIR/backup_$(date +%Y%m%d_%H%M%S).tar.gz" -C "$WORK_DIR" . || true
    fi

    TEMP_CLONE="/tmp/migu_clone_$(date +%s)"
    if git clone --depth=1 "$GITHUB_REPO" "$TEMP_CLONE"; then
        mkdir -p "$WORK_DIR"
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

if [ "$OPTION" == "2" ]; then update_service; fi
if [ "$OPTION" == "3" ]; then
    check_root
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true
    rm -f $SERVICE_FILE
    echo "卸载完成。"; exit 0
fi

# ====================== 模式 1：安装逻辑 ======================
check_root
read -p "设置工作目录 (默认: $DEFAULT_WORK_DIR): " WORK_DIR
WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}
mkdir -p "$WORK_DIR"

if [ ! -f "$WORK_DIR/app.js" ]; then
    if [ "$(ls -A $WORK_DIR)" ]; then
        find "$WORK_DIR" -maxdepth 1 ! -name '.' ! -name '*.log' -exec rm -rf {} +
    fi
    git clone --depth=1 "$GITHUB_REPO" "$WORK_DIR"
fi

read -p "设置日志路径 (默认: $WORK_DIR/migu_video.log): " LOG_FILE
LOG_FILE=${LOG_FILE:-"$WORK_DIR/migu_video.log"}
ensure_log_file "$LOG_FILE"

echo "步骤 3: 配置业务参数..."
read -p "muserId (180945xxxx): " MUSER_ID; MUSER_ID=${MUSER_ID:-180945xxxx}
read -p "mtoken (nlps0F2CDBC2A96ABD03xxxx): " MTOKEN; MTOKEN=${MTOKEN:-nlps0F2CDBC2A96ABD03xxxx}
read -p "mport (1234): " MPORT; MPORT=${MPORT:-1234}
read -p "mhost (http://10.10.1.4:1234): " MHOST; MHOST=${MHOST:-http://10.10.1.4:1234}
echo "【画质】2:标清 | 3:高清 | 4:蓝光 | 7:原画 | 9:4k"
read -p "mrateType (默认4): " MRATE_TYPE; MRATE_TYPE=${MRATE_TYPE:-4}
read -p "menableHDR (true/false, 默认true): " MENABLE_HDR; MENABLE_HDR=${MENABLE_HDR:-true}
read -p "menableH265 (true/false, 默认true): " MENABLE_H265; MENABLE_H265=${MENABLE_H265:-true}
read -p "mupdateInterval (默认6小时): " MUPDATE_INTERVAL; MUPDATE_INTERVAL=${MUPDATE_INTERVAL:-6}

# --- 新增分类控制参数 ---
echo "【分类屏蔽】多个用逗号隔开 (例: 央视,卫视 | TV:全电视 | PE:全体育)"
read -p "mignoreCategory (留空则不屏蔽): " MIGNORE_CATEGORY
MIGNORE_CATEGORY=${MIGNORE_CATEGORY:-""}

read -p "mmergeTVCategory (是否自动合并小分类 true/false, 默认true): " MMERGE_TV_CATEGORY
MMERGE_TV_CATEGORY=${MMERGE_TV_CATEGORY:-true}

if [ "$MMERGE_TV_CATEGORY" = "false" ]; then
    echo "【自定义合并】格式: 分类1,分类2 (仅在不自动合并时生效)"
    read -p "mcustomMergeCategory (留空则不合并): " MCUSTOM_MERGE_CATEGORY
    MCUSTOM_MERGE_CATEGORY=${MCUSTOM_MERGE_CATEGORY:-""}
else
    MCUSTOM_MERGE_CATEGORY=""
fi
# -----------------------

echo "步骤 4: 正在启动服务..."
install_node_deps "$WORK_DIR"
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
    echo "启动失败，请检查日志: $LOG_FILE"
fi
