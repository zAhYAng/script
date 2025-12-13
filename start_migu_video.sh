#!/bin/bash
set -e  # 遇到错误立即退出

# 定义颜色常量（美化输出）
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'  # 重置颜色

# 全局变量：服务名/工作目录/日志路径（适配咪咕视频配置）
SERVICE_NAME="migu-video"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
DEFAULT_WORK_DIR="/root/migu_video"
DEFAULT_LOG_FILE="/root/migu_video/migu_video.log"
NODE_PATH="/usr/bin/node"  # 固定 Node 路径
NPM_PATH="/usr/bin/npm"    # npm 路径（用于安装依赖）
GITHUB_REPO="https://github.com/zAhYAng/migu_video.git"
BACKUP_DIR="/root/migu_video_backup"

# ====================== 工具函数：检查是否为 root ======================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：该操作需要 root 权限，请用 sudo 运行脚本！${NC}"
        exit 1
    fi
}

# ====================== 工具函数：确保日志文件存在 ======================
ensure_log_file() {
    local log_path=$1
    local log_dir=$(dirname "$log_path")

    # 确保日志目录存在
    if [ ! -d "$log_dir" ]; then
        echo -e "${YELLOW}日志目录 $log_dir 不存在，正在创建...${NC}"
        mkdir -p "$log_dir"
        chmod 755 "$log_dir"
    fi

    # 确保日志文件存在
    if [ ! -f "$log_path" ]; then
        echo -e "${YELLOW}日志文件 $log_path 不存在，正在创建...${NC}"
        touch "$log_path"
        chmod 644 "$log_path"
        chown root:root "$log_path"  # 确保 root 可读写
        echo -e "${GREEN}日志文件创建成功：$log_path${NC}"
    else
        echo -e "${GREEN}日志文件已存在：$log_path${NC}"
    fi
}

# ====================== 工具函数：检测并安装 Node.js 依赖 ======================
install_node_deps() {
    local work_dir=$1
    echo -e "\n${YELLOW}检测并安装 Node.js 依赖${NC}"

    # 检查 npm 是否安装
    if [ ! -f "$NPM_PATH" ]; then
        echo -e "${RED}错误：未找到 npm，请先安装 Node.js 完整包（包含 npm）！${NC}"
        exit 1
    fi

    # 切换到工作目录
    cd "$work_dir"

    # 检查 package.json 是否存在
    if [ -f "package.json" ]; then
        echo -n "检测到 package.json，正在安装所有依赖..."
        $NPM_PATH install --production > /dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${YELLOW}未找到 package.json，手动安装核心依赖（axios）${NC}"
        echo -n "安装 axios 依赖..."
        $NPM_PATH install axios --save > /dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    fi

    # 验证 axios 是否安装成功
    if $NODE_PATH -e "import axios from 'axios'; console.log('axios installed')" > /dev/null 2>&1; then
        echo -e "${GREEN}axios 依赖安装成功${NC}"
    else
        echo -e "${RED}axios 依赖安装失败，请手动执行：cd $work_dir && $NPM_PATH install axios${NC}"
        exit 1
    fi
}

# ====================== 工具函数：生成 M3U 地址并提示（仅地址+端口） ======================
show_m3u_info() {
    # 提取 mhost 的 IP（兼容自定义 mhost 格式）
    local host_ip=$(echo "$MHOST" | awk -F'[:/]' '{print $4}')
    # 优先使用配置的 mport，默认 1234
    local final_port=${MPORT:-1234}

    # 核心 M3U 访问地址（仅地址+端口）
    local m3u_url="http://$host_ip:$final_port"

    echo -e "\n${GREEN}=======================================${NC}"
    echo -e "${GREEN}            M3U 文件访问地址            ${NC}"
    echo -e "${GREEN}=======================================${NC}"
    echo -e "${YELLOW}核心访问地址：${NC}${GREEN}$m3u_url${NC}"
    echo -e "\n${YELLOW}访问说明：${NC}"
    echo "  1. 直接在播放器中输入上述地址即可获取 M3U 流"
    echo "  2. 若访问失败，请检查："
    echo "     - 服务器防火墙是否开放 $final_port 端口"
    echo "     - 应用是否正常监听 $final_port 端口（netstat -tulpn | grep $final_port）"
    echo "     - 查看应用日志排查问题：tail -f $LOG_FILE"
    echo -e "${GREEN}=======================================${NC}"
}

# ====================== 工具函数：创建 systemd 服务文件 ======================
create_systemd_service() {
    # 确保工作目录存在
    if [ ! -d "$WORK_DIR" ]; then
        echo -e "${YELLOW}工作目录 $WORK_DIR 不存在，正在创建...${NC}"
        mkdir -p "$WORK_DIR"
        chmod 755 "$WORK_DIR"
    fi

    # 确保日志文件存在（调用专用函数）
    ensure_log_file "$LOG_FILE"

    echo -e "${YELLOW}正在创建 systemd 服务文件：$SERVICE_FILE${NC}"
    cat > $SERVICE_FILE << EOF
[Unit]
Description=Migu Video Service (Node.js)
After=network.target
Wants=network-online.target

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
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载 systemd 配置
    systemctl daemon-reload
    echo -e "${GREEN}systemd 服务文件创建成功${NC}"
}

# ====================== 工具函数：卸载咪咕视频服务 ======================
uninstall_service() {
    echo -e "${YELLOW}=======================================${NC}"
    echo -e "${YELLOW}          开始卸载咪咕视频服务          ${NC}"
    echo -e "${YELLOW}=======================================${NC}"

    # 1. 检查服务是否存在
    if [ -f "$SERVICE_FILE" ]; then
        # 停止服务
        echo -n "停止 $SERVICE_NAME 服务..."
        if systemctl is-active --quiet $SERVICE_NAME; then
            systemctl stop $SERVICE_NAME > /dev/null 2>&1
            echo -e "${GREEN}完成${NC}"
        else
            echo -e "${YELLOW}服务未运行${NC}"
        fi

        # 禁用开机自启
        echo -n "禁用开机自启..."
        if systemctl is-enabled --quiet $SERVICE_NAME; then
            systemctl disable $SERVICE_NAME > /dev/null 2>&1
            echo -e "${GREEN}完成${NC}"
        else
            echo -e "${YELLOW}未配置开机自启${NC}"
        fi

        # 删除服务文件
        echo -n "删除 systemd 服务文件..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl reset-failed $SERVICE_NAME > /dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${YELLOW}未找到 $SERVICE_NAME 服务文件，跳过删除${NC}"
    fi

    # 2. 清理残留进程（匹配 node app.js 进程）
    echo -n "清理残留的 Node.js 进程..."
    APP_PIDS=$(ps aux | grep "$NODE_PATH app.js" | grep -v grep | awk '{print $2}')
    if [ -n "$APP_PIDS" ]; then
        kill -9 $APP_PIDS > /dev/null 2>&1
        echo -e "${GREEN}完成（杀死进程：$APP_PIDS）${NC}"
    else
        echo -e "${YELLOW}无残留进程${NC}"
    fi

    # 3. 询问是否删除工作目录/日志（可选）
    read -p "${YELLOW}是否删除工作目录 ($WORK_DIR) 和日志文件？(y/n，默认n) ${NC}" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -n "删除工作目录和日志..."
        rm -rf "$WORK_DIR"
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${YELLOW}保留工作目录和日志文件${NC}"
    fi

    echo -e "\n${GREEN}咪咕视频服务卸载完成！${NC}"
    exit 0
}

# ====================== 工具函数：更新服务 ======================
update_service() {
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}          开始更新咪咕视频服务           ${NC}"
    echo -e "${BLUE}=======================================${NC}"

    check_root
    
    # 读取工作目录
    read -p "${YELLOW}请输入当前服务工作目录（默认：$DEFAULT_WORK_DIR）：${NC}" WORK_DIR
    WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}
    
    # 检查工作目录是否存在
    if [ ! -d "$WORK_DIR" ]; then
        echo -e "${RED}错误：工作目录 $WORK_DIR 不存在！${NC}"
        echo -e "${YELLOW}请先使用模式1安装服务${NC}"
        exit 1
    fi

    # 检查 app.js 是否存在
    if [ ! -f "$WORK_DIR/app.js" ]; then
        echo -e "${RED}错误：未找到 app.js 文件${NC}"
        exit 1
    fi

    # 备份配置文件
    echo -e "${YELLOW}第一步：备份当前配置文件${NC}"
    CONFIG_BACKUP="$BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$BACKUP_DIR"
    
    # 从现有文件中提取配置
    if [ -f "$WORK_DIR/app.js" ]; then
        echo "# 备份时间: $(date)" > "$CONFIG_BACKUP"
        echo "# 备份目录: $WORK_DIR" >> "$CONFIG_BACKUP"
        
        # 尝试从 app.js 中提取配置（如果存在）
        grep -E "(muserId|mtoken|mport|mhost|mrateType)" "$WORK_DIR/app.js" >> "$CONFIG_BACKUP" 2>/dev/null || true
        
        # 如果有 systemd 服务，也从中提取环境变量
        if [ -f "$SERVICE_FILE" ]; then
            echo "" >> "$CONFIG_BACKUP"
            echo "# Systemd 服务配置" >> "$CONFIG_BACKUP"
            grep -E "Environment=" "$SERVICE_FILE" >> "$CONFIG_BACKUP"
        fi
        
        echo -e "${GREEN}配置文件已备份到: $CONFIG_BACKUP${NC}"
    fi

    # 停止当前服务
    echo -e "${YELLOW}第二步：停止当前服务${NC}"
    if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
        echo -n "停止 systemd 服务..."
        systemctl stop $SERVICE_NAME
        echo -e "${GREEN}完成${NC}"
    else
        echo -n "停止 Node.js 进程..."
        APP_PIDS=$(ps aux | grep "$NODE_PATH app.js" | grep -v grep | awk '{print $2}')
        if [ -n "$APP_PIDS" ]; then
            kill -9 $APP_PIDS > /dev/null 2>&1
            echo -e "${GREEN}完成（杀死进程：$APP_PIDS）${NC}"
        else
            echo -e "${YELLOW}无运行中的进程${NC}"
        fi
    fi

    # 备份当前代码
    echo -e "${YELLOW}第三步：备份当前代码${NC}"
    BACKUP_CODE="$BACKUP_DIR/code_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$BACKUP_CODE" -C "$WORK_DIR" .
    echo -e "${GREEN}代码已备份到: $BACKUP_CODE${NC}"

    # 清理工作目录（保留日志和 node_modules）
    echo -e "${YELLOW}第四步：清理工作目录${NC}"
    cd "$WORK_DIR"
    
    # 备份重要文件
    TEMP_BACKUP="/tmp/migu_temp_$(date +%s)"
    mkdir -p "$TEMP_BACKUP"
    
    # 保留重要文件
    if [ -f "package.json" ]; then
        cp package.json "$TEMP_BACKUP/"
    fi
    if [ -d "node_modules" ]; then
        echo -n "保留 node_modules 目录..."
        # 只保留，不移除
        echo -e "${GREEN}完成${NC}"
    fi
    if [ -f ".env" ]; then
        cp .env "$TEMP_BACKUP/"
    fi

    # 移除其他文件（保留 node_modules 和日志）
    echo -n "清理工作目录..."
    find . -maxdepth 1 ! -name '.' ! -name 'node_modules' ! -name 'migu_video.log' ! -name '*.log' -exec rm -rf {} + 2>/dev/null || true
    echo -e "${GREEN}完成${NC}"

    # 从 GitHub 克隆最新代码
    echo -e "${YELLOW}第五步：从 GitHub 下载最新代码${NC}"
    echo -n "克隆仓库 $GITHUB_REPO ..."
    
    # 检查 git 是否安装
    if ! command -v git &> /dev/null; then
        echo -e "${RED}失败${NC}"
        echo -e "${RED}错误：未安装 git，请先安装：apt install git${NC}"
        exit 1
    fi
    
    # 克隆到临时目录
    TEMP_CLONE="/tmp/migu_clone_$(date +%s)"
    git clone --depth=1 "$GITHUB_REPO" "$TEMP_CLONE" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}成功${NC}"
        
        # 复制文件到工作目录
        echo -n "复制文件到工作目录..."
        cp -r "$TEMP_CLONE"/* "$WORK_DIR"/ 2>/dev/null || true
        cp -r "$TEMP_CLONE"/.* "$WORK_DIR"/ 2>/dev/null 2>&1 || true
        
        # 恢复保留的文件
        if [ -f "$TEMP_BACKUP/package.json" ]; then
            cp "$TEMP_BACKUP/package.json" "$WORK_DIR/"
        fi
        if [ -f "$TEMP_BACKUP/.env" ]; then
            cp "$TEMP_BACKUP/.env" "$WORK_DIR/"
        fi
        
        # 清理临时目录
        rm -rf "$TEMP_CLONE"
        rm -rf "$TEMP_BACKUP"
        
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${RED}失败${NC}"
        echo -e "${RED}错误：无法从 GitHub 克隆代码，请检查网络连接${NC}"
        
        # 尝试恢复备份
        echo -n "尝试恢复备份..."
        tar -xzf "$BACKUP_CODE" -C "$WORK_DIR"
        echo -e "${GREEN}已恢复备份${NC}"
        exit 1
    fi

    # 重新安装依赖
    echo -e "${YELLOW}第六步：重新安装依赖${NC}"
    install_node_deps "$WORK_DIR"

    # 恢复配置（如果有配置文件）
    echo -e "${YELLOW}第七步：恢复配置${NC}"
    
    # 询问是否使用原有配置
    read -p "${YELLOW}是否使用原有的配置文件？(y/n，默认y) ${NC}" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}请在重启后手动配置${NC}"
    else
        # 如果有 systemd 服务文件，重启服务即可（配置在服务文件中）
        if [ -f "$SERVICE_FILE" ]; then
            echo -n "重启 systemd 服务..."
            systemctl daemon-reload
            systemctl start $SERVICE_NAME
            echo -e "${GREEN}完成${NC}"
            
            # 检查服务状态
            sleep 2
            if systemctl is-active --quiet $SERVICE_NAME; then
                echo -e "${GREEN}服务启动成功！${NC}"
                
                # 获取配置信息
                MHOST=$(grep "Environment=\"mhost=" "$SERVICE_FILE" | cut -d= -f3 | tr -d '"')
                MPORT=$(grep "Environment=\"mport=" "$SERVICE_FILE" | cut -d= -f3 | tr -d '"')
                
                # 显示 M3U 地址
                if [ -n "$MHOST" ] && [ -n "$MPORT" ]; then
                    local host_ip=$(echo "$MHOST" | awk -F'[:/]' '{print $4}')
                    echo -e "\n${GREEN}M3U 访问地址：http://$host_ip:$MPORT${NC}"
                fi
            else
                echo -e "${YELLOW}服务启动状态异常，请检查：${NC}"
                echo "systemctl status $SERVICE_NAME"
                journalctl -u $SERVICE_NAME -n 20 --no-pager
            fi
        else
            echo -e "${YELLOW}未找到 systemd 服务，需要手动启动${NC}"
            echo -e "${YELLOW}请进入目录手动启动：${NC}"
            echo "cd $WORK_DIR"
            echo "node app.js"
        fi
    fi

    echo -e "\n${GREEN}=======================================${NC}"
    echo -e "${GREEN}          服务更新完成！                ${NC}"
    echo -e "${GREEN}=======================================${NC}"
    echo -e "${YELLOW}备份文件位置：${NC}"
    echo "  - 代码备份: $BACKUP_CODE"
    echo "  - 配置备份: $CONFIG_BACKUP"
    echo -e "\n${YELLOW}如需恢复备份：${NC}"
    echo "  tar -xzf $BACKUP_CODE -C $WORK_DIR"
    
    exit 0
}

# ====================== 工具函数：检查端口冲突 ======================
check_port() {
    local port=$1
    echo -n "检查端口 $port 是否可用..."
    
    # 检查端口是否被占用
    if netstat -tuln 2>/dev/null | grep ":$port " > /dev/null; then
        # 检查是否是自己占用
        PID=$(lsof -ti:$port 2>/dev/null || echo "")
        if [ -n "$PID" ]; then
            # 检查是否是这个服务占用的
            if ps -p $PID -o cmd= | grep -q "node app.js"; then
                echo -e "${YELLOW}被本服务占用（PID: $PID）${NC}"
                return 0  # 是自己占用的，可以继续
            fi
        fi
        echo -e "${RED}失败（已被其他进程占用）${NC}"
        echo -e "${YELLOW}当前占用进程：${NC}"
        lsof -i:$port 2>/dev/null || netstat -tulpn 2>/dev/null | grep ":$port "
        return 1
    else
        echo -e "${GREEN}可用${NC}"
        return 0
    fi
}

# ====================== 第一步：选择操作模式（启动/更新/卸载） ======================
echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}      咪咕视频 Node.js 服务管理脚本      ${NC}"
echo -e "${GREEN}=======================================${NC}"
echo -e "${YELLOW}请选择操作模式：${NC}"
echo "  1) 启动/配置服务（含开机自启）"
echo "  2) 更新服务（从 GitHub 下载最新代码）"
echo "  3) 卸载服务（停止+删除配置+清理进程）"
read -p "输入选择（1/2/3，默认1）：" OPTION
OPTION=${OPTION:-1}

# 判断操作模式
case "$OPTION" in
    2)
        # 更新服务
        update_service
        ;;
    3)
        # 卸载服务
        check_root
        read -p "请输入服务工作目录（默认：$DEFAULT_WORK_DIR）：" WORK_DIR
        WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}
        uninstall_service
        ;;
    *)
        # 默认：启动/配置服务
        ;;
esac

# ====================== 第二步：环境前置检查（启动模式） ======================
echo -e "\n${YELLOW}第一步：环境前置检查${NC}"

# 检查 Node.js 路径是否存在
echo -n "检测 Node.js 路径 ($NODE_PATH)..."
if [ ! -f "$NODE_PATH" ]; then
    echo -e "${RED}失败${NC}"
    echo -e "${RED}错误：未找到 Node.js 可执行文件（路径：$NODE_PATH）${NC}"
    exit 1
else
    NODE_VERSION=$($NODE_PATH -v)
    echo -e "${GREEN}成功${NC} (版本：$NODE_VERSION)"
fi

# 检查 npm 是否存在（用于安装依赖）
echo -n "检测 npm 路径 ($NPM_PATH)..."
if [ ! -f "$NPM_PATH" ]; then
    echo -e "${YELLOW}未找到${NC}"
    echo -e "${YELLOW}提示：将尝试使用 node_modules/.bin/npm 或手动安装依赖${NC}"
    # 尝试自动查找 npm
    NPM_PATH=$(which npm || echo "")
    if [ -z "$NPM_PATH" ]; then
        echo -e "${RED}错误：未找到 npm，请先安装 Node.js 完整包！${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}成功${NC}"
fi

# 检查 systemd 是否可用
echo -n "检测 systemd 环境..."
if ! command -v systemctl &> /dev/null; then
    echo -e "${YELLOW}未检测到${NC}"
    echo -e "${YELLOW}提示：当前系统不支持 systemd，开机自启功能将不可用${NC}"
    SUPPORT_SYSTEMD=0
else
    echo -e "${GREEN}可用${NC}"
    SUPPORT_SYSTEMD=1
fi

# 检查 git 是否安装（用于未来可能的更新）
echo -n "检测 git..."
if ! command -v git &> /dev/null; then
    echo -e "${YELLOW}未安装${NC}"
    echo -e "${YELLOW}提示：如需使用更新功能，请先安装 git：apt install git${NC}"
    HAS_GIT=0
else
    echo -e "${GREEN}已安装${NC}"
    HAS_GIT=1
fi

# ====================== 第三步：交互式输入配置参数 ======================
echo -e "\n${YELLOW}第二步：输入应用配置参数（直接回车使用默认值）${NC}"

# 1. 输入 muserId
DEFAULT_MUSER_ID="1809453805"
read -p "请输入 muserId（默认：$DEFAULT_MUSER_ID）：" MUSER_ID
MUSER_ID=${MUSER_ID:-$DEFAULT_MUSER_ID}

# 2. 输入 mtoken
DEFAULT_MTOKEN="nlps0F2CDBC2A96ABD03DF3D"
read -p "请输入 mtoken（默认：$DEFAULT_MTOKEN）：" MTOKEN
MTOKEN=${MTOKEN:-$DEFAULT_MTOKEN}

# 3. 输入 mport
DEFAULT_MPORT="1234"
read -p "请输入 mport（默认：$DEFAULT_MPORT）：" MPORT
MPORT=${MPORT:-$DEFAULT_MPORT}

# 检查端口是否可用
check_port "$MPORT"
if [ $? -ne 0 ]; then
    read -p "${YELLOW}端口冲突，是否继续？(y/n，默认n) ${NC}" -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}操作取消${NC}"
        exit 1
    fi
fi

# 4. 输入 mhost
DEFAULT_MHOST="http://10.10.1.4:1234"
read -p "请输入 mhost（默认：$DEFAULT_MHOST）：" MHOST
MHOST=${MHOST:-$DEFAULT_MHOST}

# 5. 输入 mrateType
DEFAULT_MRATE_TYPE="4"
read -p "请输入 mrateType（默认：$DEFAULT_MRATE_TYPE）：" MRATE_TYPE
MRATE_TYPE=${MRATE_TYPE:-$DEFAULT_MRATE_TYPE}

# 6. 输入工作目录
read -p "请输入工作目录（默认：$DEFAULT_WORK_DIR）：" WORK_DIR
WORK_DIR=${WORK_DIR:-$DEFAULT_WORK_DIR}

# 7. 输入日志文件路径
read -p "请输入日志文件路径（默认：$DEFAULT_LOG_FILE）：" LOG_FILE
LOG_FILE=${LOG_FILE:-$DEFAULT_LOG_FILE}

# 提前确保日志文件存在（关键逻辑）
ensure_log_file "$LOG_FILE"

# 检查 app.js 是否存在于工作目录
APP_JS_PATH="$WORK_DIR/app.js"
echo -n "检查 app.js 文件 ($APP_JS_PATH)..."
if [ ! -f "$APP_JS_PATH" ]; then
    echo -e "${YELLOW}未找到，尝试从 GitHub 下载...${NC}"
    
    if [ $HAS_GIT -eq 1 ]; then
        read -p "${YELLOW}是否从 GitHub 下载最新代码？(y/n，默认y) ${NC}" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            # 创建目录并克隆代码
            mkdir -p "$WORK_DIR"
            cd "$WORK_DIR"
            echo -n "从 GitHub 克隆代码..."
            git clone --depth=1 "$GITHUB_REPO" . > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}成功${NC}"
            else
                echo -e "${RED}失败${NC}"
                echo -e "${RED}错误：无法从 GitHub 下载代码${NC}"
                exit 1
            fi
        else
            echo -e "${RED}错误：未找到 app.js 文件，且用户选择不下载${NC}"
            exit 1
        fi
    else
        echo -e "${RED}错误：未找到 app.js 文件，且未安装 git 无法下载${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}成功${NC}"
fi

# 安装 Node.js 依赖（核心修复：解决 axios 缺失问题）
install_node_deps "$WORK_DIR"

# ====================== 第四步：确认最终配置 ======================
echo -e "\n${YELLOW}第三步：确认最终配置${NC}"
echo -e "以下是你配置的所有参数："
echo "  - muserId:   $MUSER_ID"
echo "  - mtoken:    $MTOKEN"
echo "  - mport:     $MPORT"
echo "  - mhost:     $MHOST"
echo "  - mrateType: $MRATE_TYPE"
echo "  - 工作目录:  $WORK_DIR"
echo "  - 日志文件:  $LOG_FILE"
echo "  - Node 路径: $NODE_PATH"
echo "  - npm 路径:  $NPM_PATH"

read -p "${YELLOW}确认配置无误，是否开始启动应用？(y/n) ${NC}" -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}用户取消操作，脚本退出${NC}"
    exit 0
fi

# ====================== 第五步：临时启动应用（验证） ======================
echo -e "\n${YELLOW}第四步：临时启动应用（验证配置）${NC}"
echo -n "正在启动应用..."

# 切换到工作目录执行
cd "$WORK_DIR"
muserId=$MUSER_ID \
mtoken=$MTOKEN \
mport=$MPORT \
mhost=$MHOST \
mrateType=$MRATE_TYPE \
$NODE_PATH app.js >> $LOG_FILE 2>&1 &

# 获取进程ID
APP_PID=$!
echo -e "${GREEN}成功${NC}"

# 验证进程是否存活
sleep 2
if ps -p $APP_PID > /dev/null; then
    echo -e "\n${GREEN}应用临时启动成功！${NC}"
    echo -e "进程ID（PID）：$APP_PID"
    echo -e "日志文件：$LOG_FILE"
    echo -e "临时停止应用：kill $APP_PID"
    
    # 临时启动成功后展示 M3U 地址（核心）
    show_m3u_info
else
    echo -e "\n${RED}应用启动失败！${NC}"
    echo -e "${RED}请查看日志文件排查问题：$LOG_FILE${NC}"
    # 输出详细错误日志（帮助排查）
    echo -e "${YELLOW}应用启动错误日志：${NC}"
    tail -n 20 "$LOG_FILE"
    exit 1
fi

# ====================== 第六步：配置开机自启（可选） ======================
if [ $SUPPORT_SYSTEMD -eq 1 ]; then
    echo -e "\n${YELLOW}第五步：配置开机自启（可选）${NC}"
    read -p "${YELLOW}是否配置开机自启？(y/n) ${NC}" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 检查 root 权限
        check_root

        # 停止临时进程（避免端口冲突）
        echo -n "停止临时进程 $APP_PID..."
        kill $APP_PID > /dev/null 2>&1
        sleep 2
        echo -e "${GREEN}完成${NC}"

        # 创建 systemd 服务
        create_systemd_service

        # 启用并启动服务（确保开机自启+立即生效）
        systemctl enable $SERVICE_NAME --now
        echo -e "${GREEN}开机自启配置完成！${NC}"
        
        # 验证服务状态
        echo -n "验证咪咕视频服务状态..."
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}运行正常${NC}"
            
            # 自启配置完成后再次展示 M3U 地址
            echo -e "\n${YELLOW}服务已配置开机自启，M3U 核心访问地址：${NC}${GREEN}$(echo "$MHOST" | awk -F'[:/]' '{print $4}'):$MPORT${NC}"
        else
            echo -e "${YELLOW}异常${NC}"
            echo -e "${YELLOW}提示：服务已配置开机自启，但当前运行状态异常，请执行 systemctl status $SERVICE_NAME 查看详情${NC}"
            # 输出服务错误日志
            echo -e "${YELLOW}服务错误日志：${NC}"
            journalctl -u $SERVICE_NAME -n 20 --no-pager
        fi

        # 输出自启服务管理指令
        echo -e "\n${GREEN}咪咕视频服务管理指令：${NC}"
        echo "  - 启动服务：systemctl start $SERVICE_NAME"
        echo "  - 停止服务：systemctl stop $SERVICE_NAME"
        echo "  - 重启服务：systemctl restart $SERVICE_NAME"
        echo "  - 查看状态：systemctl status $SERVICE_NAME"
        echo "  - 查看日志：tail -f $LOG_FILE"
        echo "  - 关闭开机自启：systemctl disable $SERVICE_NAME"
        echo "  - 卸载服务：sudo $0 （选择 3）"
        echo "  - 更新服务：sudo $0 （选择 2）"
    else
        echo -e "${YELLOW}跳过开机自启配置${NC}"
    fi
fi

echo -e "\n${GREEN}=======================================${NC}"
echo -e "${GREEN}          脚本执行完成                  ${NC}"
echo -e "${GREEN}=======================================${NC}"
