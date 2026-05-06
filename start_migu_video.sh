#!/bin/bash
# 遇到错误立即退出
set -e  

# ====================== 全局变量 ======================
SERVICE_NAME="migu-video"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
DEFAULT_WORK_DIR="/root/migu_video"
# 更新后的仓库地址
GITHUB_REPO="https://github.com/zAhYAng/migu_video.git"
BACKUP_DIR="/root/migu_video_backup"

# 动态获取路径
NODE_PATH=$(which node 2>/dev/null || echo "/usr/bin/node")
NPM_PATH=$(which npm 2>/dev/null || echo "/usr/bin/npm")

# ====================== 工具函数 ======================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：该操作需要 root 权限，请用 sudo 运行脚本！"
        exit 1
    fi
}

ensure_node_env() {
    echo "步骤 0: 检查 Node.js 环境..."
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "未检测到 Node.js，准备开始安装..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y curl
            curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
            apt-get install -y nodejs
        elif [ -f /etc/redhat-release ]; then
            yum install -y curl
            curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
            yum install -y nodejs
        else
            echo "不支持的系统类型，请手动安装 Node.js"
            exit 1
        fi
        NODE_PATH=$(which node)
        NPM_PATH=$(which npm)
    else
        echo "Node.js 已存在: $($NODE_PATH -v)"
    fi
}

install_node_deps() {
    local work_dir=$1
    echo "安装 Node.js 依赖..."
    cd "$work_dir"
    $NPM_PATH install axios --save --registry=https://registry.npmmirror.com
}

create_systemd_service() {
    echo "生成 Systemd 服务配置文件 (由系统托管日志)..."
    cat > $SERVICE_FILE << EOF
[Unit]
Description=Migu Video Service (Systemd Journal)
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
# 关键：直接输出到系统日志，不产生本地文件
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ====================== 逻辑部分 ======================

echo "======================================="
echo "      咪咕视频管理脚本 (系统日志版)      "
echo "======================================="
echo "  1) 安装/重置服务"
echo "  2) 更新服务 (全量覆盖)"
echo "  3) 卸载服务"
read -p "请选择操作 [1/2/3] (默认1): " OPTION
OPTION=${OPTION:-1}

check_root

if [ "$OPTION" == "3" ]; then
    echo "正在卸载..."
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true
    rm -f $SERVICE_FILE
    read -p "是否删除工作目录 $DEFAULT_WORK_DIR? [y/N]: " DEL_DIR
    [[ "$DEL_DIR" =~ ^[Yy]$ ]] && rm -rf "$DEFAULT_WORK_DIR"
    echo "卸载完成。"
    exit 0
fi

ensure_node_env

read -p "设置工作目录 (默认: $DEFAULT_WORK_DIR): " WORK_DIR
WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}

# 清理旧环境（包括旧日志文件）
if [ -d "$WORK_DIR" ]; then
    echo "正在清理工作目录，确保无旧日志残留..."
    rm -rf "$WORK_DIR"/*
else
    mkdir -p "$WORK_DIR"
fi

# 克隆新仓库
echo "正在从 $GITHUB_REPO 克隆代码..."
git clone --depth=1 "$GITHUB_REPO" "$WORK_DIR"

# 业务参数配置
echo "--- 步骤 2: 配置业务参数 ---"
read -p "muserId (180945xxxx): " MUSER_ID; MUSER_ID=${MUSER_ID:-180945xxxx}
read -p "mtoken: " MTOKEN; MTOKEN=${MTOKEN:-nlps0F2CDBC2A96ABD03xxxx}
read -p "mport (默认1234): " MPORT; MPORT=${MPORT:-1234}
read -p "mhost (默认 http://127.0.0.1:1234): " MHOST; MHOST=${MHOST:-http://127.0.0.1:1234}
read -p "mrateType (默认4): " MRATE_TYPE; MRATE_TYPE=${MRATE_TYPE:-4}
read -p "menableHDR (默认true): " MENABLE_HDR; MENABLE_HDR=${MENABLE_HDR:-true}
read -p "menableH265 (默认true): " MENABLE_H265; MENABLE_H265=${MENABLE_H265:-true}
read -p "mupdateInterval (默认6): " MUPDATE_INTERVAL; MUPDATE_INTERVAL=${MUPDATE_INTERVAL:-6}
read -p "mignoreCategory (留空则不屏蔽): " MIGNORE_CATEGORY; MIGNORE_CATEGORY=${MIGNORE_CATEGORY:-""}
read -p "mmergeTVCategory (默认true): " MMERGE_TV_CATEGORY; MMERGE_TV_CATEGORY=${MMERGE_TV_CATEGORY:-true}
MCUSTOM_MERGE_CATEGORY=""

echo "--- 步骤 3: 安装依赖并启动 ---"
install_node_deps "$WORK_DIR"

# 停止旧进程
systemctl stop $SERVICE_NAME 2>/dev/null || true
pkill -f "node app.js" || true

create_systemd_service
systemctl enable $SERVICE_NAME --now

echo "======================================="
echo "🚀 部署/更新成功！"
echo "本地目录已清空旧日志，且不再生成新的 .log 文件。"
echo "查看实时运行情况，请执行："
echo "   journalctl -u $SERVICE_NAME -f"
echo "======================================="
