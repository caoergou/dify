#!/usr/bin/env bash
set -euo pipefail

# Dify 一键安装脚本（中文版）
# 用法:
#   ./install-cn.sh                    # 交互式配置（推荐）
#   ./install-cn.sh --yes              # 使用所有推荐默认值（无需交互）
#   ./install-cn.sh --help             # 显示帮助
#   curl -sSL https://dify.ai/install-cn.sh | bash
#
# 特性:
#   - 支持 GitHub 镜像源（解决国内访问问题）
#   - 支持 Docker 镜像加速（提升拉取速度）
#   - 交互式配置，智能默认值
#   - 数据库选择（PostgreSQL/MySQL）
#   - 向量数据库选择（Weaviate/Qdrant/Milvus/Chroma/pgvector）
#   - 存储选择（本地/S3/Azure/GCS/阿里云OSS）
#   - 域名和 HTTPS 配置（支持 nginx 和 certbot）
#   - 邮件服务配置（SMTP/Gmail/SendGrid/Resend）

# 配置默认值 - 必须放在前面用于测试
INTERACTIVE=true
YES_MODE=false
DEPLOY_TYPE="private"  # "private" (本地/IP) 或 "public" (域名 + SSL)
DOMAIN="localhost"
HTTP_PORT="80"
HTTPS_PORT="443"
NGINX_HTTPS_ENABLED=false
NGINX_SERVER_NAME="_"
NGINX_ENABLE_CERTBOT_CHALLENGE=false
CERTBOT_EMAIL=""
DB_TYPE="postgresql"
VECTOR_STORE="weaviate"
STORAGE_TYPE="opendal"
OPENDAL_SCHEME="fs"
CONFIGURE_EMAIL=false

# GitHub 镜像源配置（解决国内访问问题）
GITHUB_MIRROR=""
GITHUB_REPO="langgenius/dify"
GITHUB_BRANCH="main"

# Docker 镜像加速配置
DOCKER_MIRROR=""

# ============================================
# 提前检查帮助 - 在任何其他操作之前
# ============================================
show_help() {
    echo "Dify 一键安装脚本（中文版）"
    echo ""
    echo "用法:"
    echo "  curl -sSL https://dify.ai/install-cn.sh | bash"
    echo "                                      # 交互式模式（推荐）"
    echo ""
    echo "  ./install-cn.sh                    # 交互式配置（如果已有文件）"
    echo "  ./install-cn.sh --yes              # 使用所有推荐默认值（快速安装）"
    echo "  ./install-cn.sh -y                 # 简写形式"
    echo "  ./install-cn.sh --help             # 显示此帮助"
    echo ""
    echo "一键安装示例:"
    echo "  curl -sSL https://dify.ai/install-cn.sh | bash"
    echo "  curl -sSL https://dify.ai/install-cn.sh | bash -s -- --yes"
    echo ""
    echo "功能说明:"
    echo "  - 自动检测并配置 GitHub 镜像源"
    echo "  - 自动配置 Docker 镜像加速"
    echo "  - 浅克隆 Dify 仓库（快速）"
    echo "  - 检查系统要求"
    echo "  - 引导您完成配置"
    echo "  - 生成安全密钥"
    echo "  - 启动 Dify 服务"
    echo ""
}

# 首先检查帮助
for arg in "$@"; do
    if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
        show_help
        exit 0
    fi
done

# 存储配置变量（全局作用域）
S3_BUCKET=""
S3_REGION=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
AZURE_ACCOUNT=""
AZURE_KEY=""
AZURE_CONTAINER=""
GCS_BUCKET=""
GCS_PROJECT=""
ALIYUN_BUCKET=""
ALIYUN_REGION=""
ALIYUN_ACCESS_KEY=""
ALIYUN_SECRET_KEY=""

# 邮件配置变量（全局作用域）
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASSWORD=""
SMTP_FROM=""

# ============================================
# 早期函数定义（设置所需）
# ============================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 打印函数
print_header() {
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│  Dify 一键安装脚本（中文版）                        │${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────────────┘${NC}"
    echo ""
}

print_ok() { echo -e "${GREEN}✓${NC} $1"; }
print_warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_step() { echo -e "${PURPLE}➜${NC} $1"; }
print_section() { echo ""; echo -e "${CYAN}─── $1 ─────────────────────────────────────────────${NC}"; echo ""; }

# 检查目录是否安全使用（由当前用户或 root 拥有）
is_safe_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        return 0  # 目录不存在，将安全创建
    fi

    local dir_owner
    dir_owner="$(stat -c "%u" "$dir" 2>/dev/null || echo "")"
    local current_uid
    current_uid="$(id -u)"

    # 如果由当前用户或 root 拥有则安全
    if [ "$dir_owner" = "$current_uid" ] || [ "$dir_owner" = "0" ]; then
        return 0
    fi

    return 1
}

# 测试网络连接
test_network_connection() {
    local url="$1"
    local timeout="${2:-5}"

    if command -v curl &> /dev/null; then
        if curl -s --connect-timeout "$timeout" -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
    elif command -v wget &> /dev/null; then
        if wget -q --timeout="$timeout" -O /dev/null "$url" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# 检测最佳 GitHub 镜像源
detect_github_mirror() {
    print_step "检测最佳 GitHub 镜像源..."

    # 定义可用的镜像源列表
    local mirrors=(
        "direct:https://github.com"
        "ghproxy:https://ghproxy.com/https://github.com"
        "gitclone:https://gitclone.com/github.com"
        "fastgit:https://hub.fastgit.xyz"
        "kgithub:https://kgithub.com"
    )

    # 尝试直接连接 GitHub
    if test_network_connection "https://github.com" 5; then
        print_ok "可以直接访问 GitHub"
        GITHUB_MIRROR=""
        return 0
    fi

    print_warn "无法直接访问 GitHub，正在测试镜像源..."

    # 测试各个镜像源
    for mirror in "${mirrors[@]:1}"; do
        local name="${mirror%%:*}"
        local url="${mirror#*:}"

        print_step "测试镜像源: $name"
        if test_network_connection "$url" 10; then
            print_ok "使用镜像源: $name"
            GITHUB_MIRROR="$name"
            return 0
        fi
    done

    print_warn "所有镜像源测试失败，将尝试直接连接"
    GITHUB_MIRROR=""
    return 0
}

# 获取 Git 克隆 URL
get_clone_url() {
    local repo="$1"
    local branch="$2"

    if [ -z "$GITHUB_MIRROR" ]; then
        echo "https://github.com/${repo}.git"
    else
        case "$GITHUB_MIRROR" in
            "ghproxy")
                echo "https://ghproxy.com/https://github.com/${repo}.git"
                ;;
            "gitclone")
                echo "https://gitclone.com/github.com/${repo}.git"
                ;;
            "fastgit")
                echo "https://hub.fastgit.xyz/${repo}.git"
                ;;
            "kgithub")
                echo "https://kgithub.com/${repo}.git"
                ;;
            *)
                echo "https://github.com/${repo}.git"
                ;;
        esac
    fi
}

# 配置 Docker 镜像加速
configure_docker_mirror() {
    print_step "检查 Docker 镜像加速配置..."

    # 检查 Docker daemon 是否运行
    if ! docker info &>/dev/null; then
        print_error "Docker daemon 未运行，请先启动 Docker"
        exit 1
    fi

    # 检查是否已配置镜像加速
    local daemon_json="/etc/docker/daemon.json"
    local mirrors_configured=false

    if [ -f "$daemon_json" ]; then
        if grep -q "registry-mirrors" "$daemon_json" 2>/dev/null; then
            mirrors_configured=true
            print_ok "Docker 镜像加速已配置"
        fi
    fi

    if [ "$mirrors_configured" = false ] && [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "检测到您尚未配置 Docker 镜像加速器。"
        echo "配置镜像加速器可以显著提升镜像拉取速度。"
        echo ""

        local configure_mirror
        read -p "是否配置 Docker 镜像加速器？ [Y/n] " configure_mirror
        configure_mirror="${configure_mirror:-y}"

        case "$configure_mirror" in
            [Yy]*)
                print_section "选择镜像加速器"

                MIRROR_CHOICE=$(ask_choice "请选择镜像加速器" "1" \
                    "阿里云镜像加速器（推荐，需登录获取专属地址）" \
                    "网易镜像加速器" \
                    "中科大镜像加速器" \
                    "腾讯云镜像加速器" \
                    "自定义镜像加速器地址" \
                    "跳过配置")

                case $MIRROR_CHOICE in
                    1)
                        echo ""
                        echo "请访问 https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors"
                        echo "获取您的专属加速器地址（格式：https://xxxxxx.mirror.aliyuncs.com）"
                        echo ""
                        DOCKER_MIRROR=$(ask "请输入您的阿里云镜像加速器地址" "")
                        ;;
                    2)
                        DOCKER_MIRROR="https://hub-mirror.c.163.com"
                        ;;
                    3)
                        DOCKER_MIRROR="https://docker.mirrors.ustc.edu.cn"
                        ;;
                    4)
                        DOCKER_MIRROR="https://mirror.ccs.tencentyun.com"
                        ;;
                    5)
                        DOCKER_MIRROR=$(ask "请输入镜像加速器地址" "")
                        ;;
                    6)
                        print_ok "跳过镜像加速器配置"
                        return 0
                        ;;
                esac

                if [ -n "$DOCKER_MIRROR" ]; then
                    configure_docker_daemon "$DOCKER_MIRROR"
                fi
                ;;
            *)
                print_ok "跳过镜像加速器配置"
                ;;
        esac
    fi
}

# 配置 Docker daemon
configure_docker_daemon() {
    local mirror="$1"

    if [ -z "$mirror" ]; then
        return 0
    fi

    print_step "配置 Docker 镜像加速..."

    local daemon_json="/etc/docker/daemon.json"
    local temp_file="/tmp/daemon.json.$$"

    # 检查是否有 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        print_warn "需要 root 权限来配置 Docker daemon"
        print_step "请手动执行以下命令："
        echo ""
        echo "sudo mkdir -p /etc/docker"
        echo "sudo tee /etc/docker/daemon.json <<EOF"
        echo "{"
        echo "  \"registry-mirrors\": [\"$mirror\"]"
        echo "}"
        echo "EOF"
        echo "sudo systemctl daemon-reload"
        echo "sudo systemctl restart docker"
        echo ""
        return 0
    fi

    # 创建目录
    mkdir -p /etc/docker

    # 写入配置
    cat > "$temp_file" <<EOF
{
  "registry-mirrors": ["$mirror"]
}
EOF

    # 如果已有配置，尝试合并
    if [ -f "$daemon_json" ] && command -v jq &>/dev/null; then
        jq --arg mirror "$mirror" '.registry-mirrors = [$mirror]' "$daemon_json" > "$temp_file" 2>/dev/null || true
    fi

    mv "$temp_file" "$daemon_json"
    chmod 644 "$daemon_json"

    # 重启 Docker
    systemctl daemon-reload
    systemctl restart docker

    print_ok "Docker 镜像加速配置完成"
}

# 检查是否在 Dify 仓库的 docker 目录中，
# 或者是否需要浅克隆仓库
setup_working_directory() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 检查是否已在包含所需文件的 docker 目录中
    if [ -f "${script_dir}/.env.example" ] && [ -f "${script_dir}/docker-compose.yaml" ]; then
        if ! is_safe_directory "$script_dir"; then
            print_error "目录 $script_dir 不属于您或 root。出于安全考虑，中止操作。"
            exit 1
        fi
        cd "$script_dir"
        SCRIPT_DIR="$script_dir"
        return 0
    fi

    # 检查当前目录是否有所需文件
    if [ -f ".env.example" ] && [ -f "docker-compose.yaml" ]; then
        local current_dir
        current_dir="$(pwd)"
        if ! is_safe_directory "$current_dir"; then
            print_error "目录 $current_dir 不属于您或 root。出于安全考虑，中止操作。"
            exit 1
        fi
        SCRIPT_DIR="$current_dir"
        cd "$SCRIPT_DIR"
        return 0
    fi

    # 检查父目录是否有包含所需文件的 docker 子目录
    if [ -d "../docker" ] && [ -f "../docker/.env.example" ] && [ -f "../docker/docker-compose.yaml" ]; then
        local parent_dir
        parent_dir="$(cd .. && pwd)/docker"
        if ! is_safe_directory "$parent_dir"; then
            print_error "目录 $parent_dir 不属于您或 root。出于安全考虑，中止操作。"
            exit 1
        fi
        cd "../docker"
        SCRIPT_DIR="$(pwd)"
        return 0
    fi

    # 需要克隆仓库
    echo "正在设置 Dify 安装环境..."
    local install_dir="dify"
    local clone_dir="$install_dir"

    # 检查 dify 目录是否已存在且包含 docker 子目录
    if [ -d "$clone_dir" ] && [ -d "$clone_dir/docker" ] && [ -f "$clone_dir/docker/.env.example" ] && [ -f "$clone_dir/docker/docker-compose.yaml" ]; then
        if ! is_safe_directory "$clone_dir"; then
            print_error "目录 $clone_dir 不属于您或 root。出于安全考虑，中止操作。"
            exit 1
        fi
        cd "$clone_dir/docker"
        SCRIPT_DIR="$(pwd)"
        print_ok "使用现有 Dify 安装目录: $SCRIPT_DIR"
        return 0
    fi

    # 检测 GitHub 镜像源
    detect_github_mirror

    # 克隆或更新仓库
    if [ -d "$clone_dir" ]; then
        if ! is_safe_directory "$clone_dir"; then
            print_error "目录 $clone_dir 不属于您或 root。出于安全考虑，中止操作。"
            exit 1
        fi
        cd "$clone_dir"
        print_step "更新 Dify 仓库..."
        if git pull origin "$GITHUB_BRANCH" 2>/dev/null; then
            print_ok "Dify 仓库已更新"
        else
            print_warn "无法更新，使用现有版本"
        fi
        cd ..
    else
        print_header

        # 检查 git 是否安装
        if ! command -v git &> /dev/null; then
            print_error "Git 未安装"
            echo "请先安装 Git 或手动克隆仓库。"
            echo ""
            echo "安装 Git:"
            echo "  Ubuntu/Debian: sudo apt-get install git"
            echo "  CentOS/RHEL:   sudo yum install git"
            echo "  macOS:         brew install git"
            exit 1
        fi

        echo "正在克隆 Dify 仓库（浅克隆，速度很快）..."
        echo ""
        print_step "克隆源: ${GITHUB_REPO} (分支: ${GITHUB_BRANCH})"
        if [ -n "$GITHUB_MIRROR" ]; then
            echo "使用镜像: $GITHUB_MIRROR"
        fi

        # 验证父目录是否安全
        local parent_dir
        parent_dir="$(pwd)"
        if ! is_safe_directory "$parent_dir"; then
            print_error "当前目录不属于您或 root。出于安全考虑，中止操作。"
            exit 1
        fi

        local clone_url
        clone_url=$(get_clone_url "$GITHUB_REPO" "$GITHUB_BRANCH")

        # 设置 git 超时
        export GIT_HTTP_LOW_SPEED_LIMIT=1000
        export GIT_HTTP_LOW_SPEED_TIME=30

        local clone_success=false
        local max_retries=3
        local retry=0

        while [ $retry -lt $max_retries ]; do
            if git clone --depth 1 --branch "$GITHUB_BRANCH" "$clone_url" "$clone_dir" 2>&1; then
                clone_success=true
                break
            fi

            retry=$((retry + 1))
            if [ $retry -lt $max_retries ]; then
                print_warn "克隆失败，正在重试 ($retry/$max_retries)..."
                sleep 2

                # 如果使用镜像失败，尝试切换镜像
                if [ -n "$GITHUB_MIRROR" ]; then
                    case "$GITHUB_MIRROR" in
                        "ghproxy")
                            GITHUB_MIRROR="gitclone"
                            ;;
                        "gitclone")
                            GITHUB_MIRROR="fastgit"
                            ;;
                        "fastgit")
                            GITHUB_MIRROR="kgithub"
                            ;;
                        *)
                            GITHUB_MIRROR=""
                            ;;
                    esac
                    clone_url=$(get_clone_url "$GITHUB_REPO" "$GITHUB_BRANCH")
                    print_step "切换到镜像: ${GITHUB_MIRROR:-直连}"
                fi
            fi
        done

        if [ "$clone_success" = false ]; then
            print_error "克隆仓库失败"
            echo ""
            echo "请检查网络连接后重试。"
            echo ""
            echo "如果问题持续存在，请尝试："
            echo "1. 配置代理: export https_proxy=http://your-proxy:port"
            echo "2. 使用 VPN"
            echo "3. 手动下载: wget https://github.com/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.zip"
            exit 1
        fi

        print_ok "Dify 仓库克隆完成"
    fi

    cd "$clone_dir/docker"
    SCRIPT_DIR="$(pwd)"
    echo ""
    print_ok "Dify 文件准备就绪: $SCRIPT_DIR"
    echo ""
}

# 清理陷阱
TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

# 在任何其他操作之前运行工作目录设置
setup_working_directory

# ============================================
# 剩余函数定义
# ============================================

# 转义字符串以便安全用于 sed 替换
escape_sed() {
    printf '%s\n' "$1" | sed -e ':a' -e '$!N' -e '$!ba' -e 's/[\/&|#$\!`"]/\\&/g'
}

print_success() {
    echo ""
    echo -e "${GREEN}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│  安装完成！🎉                                       │${NC}"
    echo -e "${GREEN}└─────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${GREEN}✓ Dify 正在启动！${NC}"
    echo ""

    local protocol="http"
    if [ "$NGINX_HTTPS_ENABLED" = true ]; then
        protocol="https"
    fi
    local access_url="${protocol}://${DOMAIN}"
    if [ "$protocol" = "http" ] && [ "$HTTP_PORT" != "80" ]; then
        access_url="${access_url}:${HTTP_PORT}"
    elif [ "$protocol" = "https" ] && [ "$HTTPS_PORT" != "443" ]; then
        access_url="${access_url}:${HTTPS_PORT}"
    fi

    echo "下一步：         在浏览器中打开 ${access_url}/install"
    echo "                 完成初始设置。"
    echo ""
    echo "访问地址：       ${access_url}"
    echo ""
    echo "常用命令："
    echo "  （在目录 $SCRIPT_DIR 中运行）"
    echo "  查看日志：       docker compose logs -f"
    echo "  停止服务：       docker compose down"
    echo "  启动服务：       docker compose up -d"
    echo "  查看状态：       docker compose ps"
    echo ""
    echo "配置信息："
    echo "  工作目录：       $SCRIPT_DIR"
    echo "  配置文件：       $SCRIPT_DIR/.env"
    if [ -n "${BACKUP_FILE:-}" ]; then
        echo "  备份文件：       $BACKUP_FILE"
    fi
    echo ""
    if [ "$DEPLOY_TYPE" = "public" ] && [ "$NGINX_HTTPS_ENABLED" = true ] && [ "$NGINX_ENABLE_CERTBOT_CHALLENGE" = true ]; then
        echo "SSL 证书："
        echo "  要启用 HTTPS 和 Certbot，请确保："
        echo "  1. 您的域名 ${DOMAIN} 已指向此服务器"
        echo "  2. 端口 80 和 443 已对外开放"
        echo "  3. 运行：docker compose --profile certbot up -d"
        echo ""
    fi
    echo "获取帮助："
    echo "  文档：           https://docs.dify.ai"
    echo "  问题反馈：       https://github.com/langgenius/dify/issues"
    echo ""
    echo "云服务："
    echo "  如果自托管太复杂，可以尝试 Dify 云服务："
    echo "  https://cloud.dify.ai"
    echo ""
}

# 询问函数
ask() {
    local prompt="$1"
    local default="$2"
    local result
    read -p "$prompt [$default] " result
    echo "${result:-$default}"
}

ask_choice() {
    local prompt="$1"
    local default="$2"
    shift 2
    local options=("$@")

    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "  [$((i+1))] ${options[$i]}"
    done

    local result
    read -p "请选择：[$default] " result
    result="${result:-$default}"

    if ! [[ "$result" =~ ^[0-9]+$ ]] || [ "$result" -lt 1 ] || [ "$result" -gt "${#options[@]}" ]; then
        result="$default"
    fi

    echo "$result"
}

ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local default_display="$([ "$default" = true ] && echo "Y/n" || echo "y/N")"

    local result
    read -p "$prompt [$default_display] " result
    result="${result:-$([ "$default" = true ] && echo "y" || echo "n")}"

    case "$result" in
        [Yy]*) echo "true" ;;
        *) echo "false" ;;
    esac
}

# 密钥生成 - 安全随机生成，有适当的回退
generate_secret_key() {
    # 首先尝试 openssl（最常见）
    if command -v openssl &> /dev/null; then
        openssl rand -base64 42
        return
    fi

    # 尝试 Python 的 secrets 模块（安全）
    if command -v python3 &> /dev/null; then
        python3 -c "import secrets; import base64; print(base64.b64encode(secrets.token_bytes(32)).decode())"
        return
    fi

    # 尝试 /dev/urandom（大多数类 Unix 系统可用）
    if [ -c /dev/urandom ]; then
        # 使用 uuencode（如果可用）
        if command -v uuencode &> /dev/null; then
            head -c 48 /dev/urandom 2>/dev/null | uuencode -m - | tail -n +2 | tr -d '\n'
            return
        fi

        # 使用 base64（如果可用）
        if command -v base64 &> /dev/null; then
            head -c 48 /dev/urandom 2>/dev/null | base64 | tr -d '\n'
            return
        fi
    fi

    # 最后手段：如果到这里，无法生成安全密钥
    print_error "无法生成安全密钥：未找到安全随机源"
    echo "请安装 openssl 或 Python 3.6+ 后重试。"
    exit 1
}

generate_password() {
    local length=${1:-16}

    # 首先尝试 openssl
    if command -v openssl &> /dev/null; then
        openssl rand -base64 "$((length * 2))" 2>/dev/null | tr -d '/+=' | cut -c1-"$length"
        return
    fi

    # 尝试 Python 的 secrets 模块
    if command -v python3 &> /dev/null; then
        python3 -c "import secrets; import string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range($length)))"
        return
    fi

    # 尝试 /dev/urandom
    if [ -c /dev/urandom ]; then
        tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$length"
        return
    fi

    # 最后手段
    print_error "无法生成安全密码：未找到安全随机源"
    echo "请安装 openssl 或 Python 3.6+ 后重试。"
    exit 1
}

# 获取占用端口的进程
get_port_process() {
    local port=$1
    if command -v lsof &> /dev/null; then
        lsof -i :"$port" -t 2>/dev/null | head -1 | xargs ps -p 2>/dev/null | tail -1 || echo ""
    elif command -v ss &> /dev/null; then
        local pid=$(ss -tulnp 2>/dev/null | grep ":$port " | grep -oP 'pid=\K[0-9]+' | head -1)
        if [ -n "$pid" ]; then
            ps -p "$pid" -o comm= 2>/dev/null || echo "PID $pid"
        fi
    fi
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if command -v lsof &> /dev/null; then
        if lsof -i :"$port" &> /dev/null; then
            return 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":$port " &> /dev/null; then
            return 1
        fi
    elif command -v ss &> /dev/null; then
        if ss -tuln 2>/dev/null | grep -q ":$port " &> /dev/null; then
            return 1
        fi
    fi
    return 0
}

# 检查并处理端口冲突
check_and_handle_port() {
    local port=$1
    local port_name=$2

    if check_port "$port"; then
        return 0  # 端口可用
    fi

    local process=$(get_port_process "$port")
    print_warn "端口 $port ($port_name) 已被占用"
    if [ -n "$process" ]; then
        echo "    占用进程: $process"
    fi

    if [ "$INTERACTIVE" = true ]; then
        echo ""
        local choice
        read -p "请输入新的 $port_name 端口号，或按回车继续使用当前端口: " choice
        if [ -n "$choice" ] && [[ "$choice" =~ ^[0-9]+$ ]]; then
            eval "${port_name}_PORT=$choice"
            print_ok "将使用端口 $choice 作为 $port_name"
            return 0
        fi
        print_warn "继续使用冲突端口，服务可能无法启动。"
    else
        print_warn "继续使用冲突端口，服务可能无法启动。"
    fi
    return 1
}

check_ports() {
    local has_conflict=false

    if ! check_and_handle_port "$HTTP_PORT" "HTTP"; then
        has_conflict=true
    fi

    if [ "$NGINX_HTTPS_ENABLED" = true ]; then
        if ! check_and_handle_port "$HTTPS_PORT" "HTTPS"; then
            has_conflict=true
        fi
    fi

    if [ "$has_conflict" = true ]; then
        echo ""
        print_warn "存在端口冲突，Dify 可能无法正常启动。"
        echo "    安装后，您可以修改 .env 中的端口并重启："
        echo "    docker compose down && docker compose up -d"
    fi
}

# 前置条件检查
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker 未安装"
        echo "请先安装 Docker：https://docs.docker.com/get-docker/"
        echo ""
        echo "安装 Docker (Ubuntu/Debian):"
        echo "  curl -fsSL https://get.docker.com | bash"
        echo ""
        echo "安装 Docker (CentOS/RHEL):"
        echo "  yum install -y docker-ce docker-ce-cli containerd.io"
        exit 1
    fi
    local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
    print_ok "Docker 已安装 (v$docker_version)"

    # 检查 Docker daemon 是否运行
    if ! docker info &>/dev/null; then
        print_error "Docker daemon 未运行"
        echo "请启动 Docker 服务："
        echo "  sudo systemctl start docker"
        exit 1
    fi
    print_ok "Docker daemon 正在运行"
}

check_docker_compose() {
    if ! docker compose version &> /dev/null; then
        print_error "Docker Compose 未安装"
        echo "请安装 Docker Compose 插件"
        echo "Docker Compose 现在作为 Docker 插件提供"
        exit 1
    fi
    local compose_version=$(docker compose version | awk '{print $4}' | sed 's/,//')
    print_ok "Docker Compose 已安装 (v$compose_version)"
}

check_system_resources() {
    local cpu_cores
    if [[ "$(uname)" == "Darwin" ]]; then
        cpu_cores=$(sysctl -n hw.ncpu)
    else
        cpu_cores=$(nproc)
    fi

    if [ "$cpu_cores" -lt 2 ]; then
        print_warn "检测到 $cpu_cores 个 CPU 核心。Dify 需要至少 2 个核心。"
        echo "    建议使用 Dify 云服务以获得更好的性能：https://cloud.dify.ai"
    else
        print_ok "CPU: $cpu_cores 核心（最低要求 2 核心）"
    fi

    local total_ram_mb
    if [[ "$(uname)" == "Darwin" ]]; then
        total_ram_mb=$(($(sysctl -n hw.memsize) / 1024 / 1024))
    else
        total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)
    fi

    local total_ram_gb=$((total_ram_mb / 1024))
    if [ "$total_ram_mb" -lt 4000 ]; then
        print_warn "检测到 ${total_ram_gb}GB 内存。Dify 需要至少 4GB 内存。"
        echo "    建议使用 Dify 云服务以获得更好的性能：https://cloud.dify.ai"
    else
        print_ok "内存: ${total_ram_gb}GB（最低要求 4GB）"
    fi
}

check_disk_space() {
    local available_mb
    if [[ "$(uname)" == "Darwin" ]]; then
        available_mb=$(df -m . | awk 'NR==2 {print $4}')
    else
        available_mb=$(df -m . | awk 'NR==2 {print $4}')
    fi

    local available_gb=$((available_mb / 1024))
    if [ "$available_mb" -lt 20000 ]; then
        print_warn "磁盘剩余空间仅 ${available_gb}GB。建议至少 20GB 用于 Dify。"
        echo "    拉取 Docker 镜像时可能出现问题。"
    else
        print_ok "磁盘: ${available_gb}GB 可用（建议至少 20GB）"
    fi
}

check_prerequisites() {
    echo "正在检查系统环境..."
    check_docker
    check_docker_compose
    check_system_resources
    check_disk_space
    echo ""
}

# 存储配置
configure_s3() {
    echo ""
    echo "AWS S3 配置："
    S3_BUCKET=$(ask "S3 Bucket 名称" "")
    S3_REGION=$(ask "S3 区域" "us-east-1")
    S3_ACCESS_KEY=$(ask "AWS Access Key ID" "")
    S3_SECRET_KEY=$(ask "AWS Secret Access Key" "")
}

configure_azure() {
    echo ""
    echo "Azure Blob Storage 配置："
    AZURE_ACCOUNT=$(ask "Azure 账户名称" "")
    AZURE_KEY=$(ask "Azure 账户密钥" "")
    AZURE_CONTAINER=$(ask "Azure 容器名称" "")
}

configure_gcs() {
    echo ""
    echo "Google Cloud Storage 配置："
    GCS_BUCKET=$(ask "GCS Bucket 名称" "")
    GCS_PROJECT=$(ask "GCP 项目 ID" "")
    echo "请将您的服务账号密钥文件放在当前目录，命名为 gcs-credentials.json"
}

configure_aliyun() {
    echo ""
    echo "阿里云 OSS 配置："
    ALIYUN_BUCKET=$(ask "OSS Bucket 名称" "")
    ALIYUN_REGION=$(ask "OSS 区域" "oss-cn-hangzhou")
    ALIYUN_ACCESS_KEY=$(ask "Access Key ID" "")
    ALIYUN_SECRET_KEY=$(ask "Access Key Secret" "")
}

# 邮件配置
configure_email() {
    echo ""
    echo "邮件服务配置："
    MAIL_PROVIDER=$(ask_choice "邮件服务提供商" "1" \
        "SMTP 服务器（通用）" \
        "Gmail" \
        "SendGrid" \
        "Resend")

    case $MAIL_PROVIDER in
        1)
            SMTP_HOST=$(ask "SMTP 服务器地址" "")
            SMTP_PORT=$(ask "SMTP 端口" "587")
            SMTP_USER=$(ask "SMTP 用户名" "")
            SMTP_PASSWORD=$(ask "SMTP 密码" "")
            SMTP_FROM=$(ask "发件人邮箱" "$SMTP_USER")
            ;;
        2)
            SMTP_HOST="smtp.gmail.com"
            SMTP_PORT="587"
            SMTP_USER=$(ask "Gmail 邮箱地址" "")
            SMTP_PASSWORD=$(ask "Gmail 应用专用密码" "")
            SMTP_FROM="$SMTP_USER"
            ;;
        3)
            SMTP_HOST="smtp.sendgrid.net"
            SMTP_PORT="587"
            SMTP_USER="apikey"
            SMTP_PASSWORD=$(ask "SendGrid API Key" "")
            SMTP_FROM=$(ask "发件人邮箱" "")
            ;;
        4)
            SMTP_HOST="smtp.resend.com"
            SMTP_PORT="587"
            SMTP_USER="resend"
            SMTP_PASSWORD=$(ask "Resend API Key" "")
            SMTP_FROM=$(ask "发件人邮箱" "")
            ;;
    esac
}

# 交互式配置
interactive_config() {
    print_header
    echo "我将问您几个简单的问题。按回车键接受默认值（推荐）。"
    echo ""

    print_section "部署类型"

    DEPLOY_CHOICE=$(ask_choice "部署类型" "1" \
        "私有 / 本地 ⭐ 推荐（localhost/IP，无 SSL）" \
        "公开 / 生产环境（带域名，可选 SSL）")

    if [ "$DEPLOY_CHOICE" = "2" ]; then
        DEPLOY_TYPE="public"
        print_section "域名和网络"

        DOMAIN=$(ask "域名（例如：dify.example.com）" "")
        while [ -z "$DOMAIN" ]; do
            DOMAIN=$(ask "域名（公开部署必填）" "")
        done
        NGINX_SERVER_NAME="$DOMAIN"

        HTTP_PORT=$(ask "HTTP 端口" "80")
        HTTPS_PORT=$(ask "HTTPS 端口" "443")

        print_section "SSL 证书"

        SSL_CHOICE=$(ask_choice "SSL 证书选项" "1" \
            "无 SSL（仅使用 HTTP）⭐ 推荐用于测试" \
            "启用 SSL（使用 Let's Encrypt / Certbot）" \
            "启用 SSL（自定义证书）")

        case $SSL_CHOICE in
            1)
                NGINX_HTTPS_ENABLED=false
                ;;
            2)
                NGINX_HTTPS_ENABLED=true
                NGINX_ENABLE_CERTBOT_CHALLENGE=true
                CERTBOT_EMAIL=$(ask "Let's Encrypt 通知邮箱" "")
                ;;
            3)
                NGINX_HTTPS_ENABLED=true
                echo ""
                echo "注意：您需要将 SSL 证书放在 ./nginx/ssl/ 目录下"
                echo "  - 证书：./nginx/ssl/dify.crt"
                echo "  - 私钥：./nginx/ssl/dify.key"
                ;;
        esac
    else
        DEPLOY_TYPE="private"
        print_section "网络配置"

        DOMAIN=$(ask "IP 地址或主机名" "localhost")
        HTTP_PORT=$(ask "HTTP 端口" "80")
        NGINX_SERVER_NAME="$DOMAIN"
        NGINX_HTTPS_ENABLED=false
    fi

    print_section "数据库选择"

    DB_CHOICE=$(ask_choice "主数据库" "1" \
        "PostgreSQL ⭐ 推荐（支持最好，最可靠）" \
        "MySQL")

    case $DB_CHOICE in
        1) DB_TYPE="postgresql" ;;
        2) DB_TYPE="mysql" ;;
    esac

    print_section "向量数据库选择"

    VECTOR_CHOICE=$(ask_choice "向量数据库" "1" \
        "Weaviate ⭐ 推荐（与 Dify 测试最充分）" \
        "Qdrant（轻量级，快速）" \
        "Milvus（企业级，功能强大）" \
        "Chroma（简单，适合开发）" \
        "pgvector（使用 PostgreSQL，服务更少）")

    case $VECTOR_CHOICE in
        1) VECTOR_STORE="weaviate" ;;
        2) VECTOR_STORE="qdrant" ;;
        3) VECTOR_STORE="milvus" ;;
        4) VECTOR_STORE="chroma" ;;
        5) VECTOR_STORE="pgvector" ;;
    esac

    print_section "存储选择"

    STORAGE_CHOICE=$(ask_choice "文件存储" "1" \
        "本地文件系统 ⭐ 推荐（最简单）" \
        "AWS S3" \
        "Azure Blob Storage" \
        "Google Cloud Storage" \
        "阿里云 OSS")

    case $STORAGE_CHOICE in
        1) STORAGE_TYPE="opendal"; OPENDAL_SCHEME="fs" ;;
        2) STORAGE_TYPE="s3"; configure_s3 ;;
        3) STORAGE_TYPE="azure"; configure_azure ;;
        4) STORAGE_TYPE="gcs"; configure_gcs ;;
        5) STORAGE_TYPE="aliyun"; configure_aliyun ;;
    esac

    print_section "邮件服务（可选）"

    CONFIGURE_EMAIL=$(ask_yes_no "配置邮件服务？（用于密码重置等）" false)

    if [ "$CONFIGURE_EMAIL" = true ]; then
        configure_email
    fi

    print_section "确认配置"

    echo "您的配置："
    echo "  ✓ 部署类型：$([ "$DEPLOY_TYPE" = "public" ] && echo "公开（带域名）" || echo "私有 / 本地")"
    echo "  ✓ 域名/IP：$DOMAIN"
    if [ "$DEPLOY_TYPE" = "public" ]; then
        echo "  ✓ SSL：$([ "$NGINX_HTTPS_ENABLED" = true ] && echo "已启用" || echo "未启用")"
    fi
    echo "  ✓ HTTP 端口：$HTTP_PORT"
    if [ "$NGINX_HTTPS_ENABLED" = true ]; then
        echo "  ✓ HTTPS 端口：$HTTPS_PORT"
    fi
    echo "  ✓ 数据库：$DB_TYPE"
    echo "  ✓ 向量数据库：$VECTOR_STORE"
    echo "  ✓ 存储：$([ "$STORAGE_TYPE" = "opendal" ] && echo "本地文件系统" || echo "$STORAGE_TYPE")"
    echo "  ✓ 邮件：$([ "$CONFIGURE_EMAIL" = true ] && echo "已配置" || echo "未配置")"
    echo ""
    echo "所有密钥将自动生成，安全且唯一。"
    echo ""

    read -p "按回车键开始安装，或按 Ctrl+C 取消。 "
    echo ""
}

# 生成密钥
generate_secrets() {
    echo "正在生成安全密钥..."
    SECRET_KEY=$(generate_secret_key)
    DB_PASSWORD=$(generate_password)
    REDIS_PASSWORD=$(generate_password)
    SANDBOX_API_KEY=$(generate_secret_key)
    PLUGIN_DAEMON_KEY=$(generate_secret_key)
    PLUGIN_DIFY_INNER_API_KEY=$(generate_secret_key)
    print_ok "SECRET_KEY 已生成"
    print_ok "DB_PASSWORD 已生成"
    print_ok "REDIS_PASSWORD 已生成"
    print_ok "SANDBOX_API_KEY 已生成"
    print_ok "PLUGIN_DAEMON_KEY 已生成"
    print_ok "PLUGIN_DIFY_INNER_API_KEY 已生成"
    echo ""
}

# 更新 .env 文件（带适当的转义）
update_env() {
    local key="$1"
    local value="$2"
    local file="$3"
    sed -i.bak "s|^${key}=.*|${key}=$(escape_sed "$value")|" "$file"
    TEMP_FILES+=("$file.bak")
}

# 创建 .env 文件
create_env_file() {
    echo "正在创建配置..."

    if [ -f ".env" ]; then
        BACKUP_FILE=".env.backup-$(date +%Y%m%d-%H%M%S)"
        cp ".env" "$BACKUP_FILE"
        # 同时设置备份文件的权限限制
        chmod 600 "$BACKUP_FILE" 2>/dev/null || true
        print_ok "已备份现有 .env 文件到 $BACKUP_FILE"
    fi

    if [ ! -f ".env.example" ]; then
        print_error ".env.example 文件未找到！"
        exit 1
    fi
    cp ".env.example" ".env"

    local protocol="http"
    if [ "$NGINX_HTTPS_ENABLED" = true ]; then
        protocol="https"
    fi
    local base_url="${protocol}://${DOMAIN}"
    if [ "$protocol" = "http" ] && [ "$HTTP_PORT" != "80" ]; then
        base_url="${base_url}:${HTTP_PORT}"
    elif [ "$protocol" = "https" ] && [ "$HTTPS_PORT" != "443" ]; then
        base_url="${base_url}:${HTTPS_PORT}"
    fi

    # 构建 URL - FILES_URL 使用与其他服务相同的基础 URL
    # 注意：FILES_URL 应该指向与 Web 界面相同的来源
    # 内部文件访问通过 INTERNAL_FILES_URL 单独处理
    local files_url="$base_url"

    update_env "SECRET_KEY" "$SECRET_KEY" ".env"
    update_env "DB_PASSWORD" "$DB_PASSWORD" ".env"
    update_env "REDIS_PASSWORD" "$REDIS_PASSWORD" ".env"
    update_env "SANDBOX_API_KEY" "$SANDBOX_API_KEY" ".env"
    update_env "PLUGIN_DAEMON_KEY" "$PLUGIN_DAEMON_KEY" ".env"
    update_env "PLUGIN_DIFY_INNER_API_KEY" "$PLUGIN_DIFY_INNER_API_KEY" ".env"

    update_env "CONSOLE_API_URL" "$base_url" ".env"
    update_env "CONSOLE_WEB_URL" "$base_url" ".env"
    update_env "SERVICE_API_URL" "$base_url" ".env"
    update_env "APP_WEB_URL" "$base_url" ".env"
    update_env "FILES_URL" "$files_url" ".env"
    update_env "INTERNAL_FILES_URL" "http://api:5001" ".env"

    update_env "DB_TYPE" "$DB_TYPE" ".env"
    update_env "VECTOR_STORE" "$VECTOR_STORE" ".env"
    update_env "COMPOSE_PROFILES" "$VECTOR_STORE,$DB_TYPE" ".env"

    update_env "NGINX_SERVER_NAME" "$NGINX_SERVER_NAME" ".env"
    update_env "NGINX_HTTPS_ENABLED" "$NGINX_HTTPS_ENABLED" ".env"
    update_env "NGINX_PORT" "$HTTP_PORT" ".env"
    update_env "NGINX_SSL_PORT" "$HTTPS_PORT" ".env"
    update_env "EXPOSE_NGINX_PORT" "$HTTP_PORT" ".env"
    update_env "EXPOSE_NGINX_SSL_PORT" "$HTTPS_PORT" ".env"

    if [ "$NGINX_HTTPS_ENABLED" = true ] && [ -n "$CERTBOT_EMAIL" ]; then
        update_env "NGINX_ENABLE_CERTBOT_CHALLENGE" "true" ".env"
        update_env "CERTBOT_EMAIL" "$CERTBOT_EMAIL" ".env"
        update_env "CERTBOT_DOMAIN" "$DOMAIN" ".env"
    fi

    update_env "STORAGE_TYPE" "$STORAGE_TYPE" ".env"
    if [ "$STORAGE_TYPE" = "opendal" ]; then
        update_env "OPENDAL_SCHEME" "$OPENDAL_SCHEME" ".env"
    fi

    if [ "$STORAGE_TYPE" = "s3" ]; then
        update_env "S3_BUCKET_NAME" "$S3_BUCKET" ".env"
        update_env "S3_REGION" "$S3_REGION" ".env"
        update_env "S3_ACCESS_KEY" "$S3_ACCESS_KEY" ".env"
        update_env "S3_SECRET_KEY" "$S3_SECRET_KEY" ".env"
    elif [ "$STORAGE_TYPE" = "azure" ]; then
        update_env "AZURE_BLOB_ACCOUNT_NAME" "$AZURE_ACCOUNT" ".env"
        update_env "AZURE_BLOB_ACCOUNT_KEY" "$AZURE_KEY" ".env"
        update_env "AZURE_BLOB_CONTAINER_NAME" "$AZURE_CONTAINER" ".env"
    elif [ "$STORAGE_TYPE" = "aliyun" ]; then
        update_env "ALIYUN_OSS_BUCKET_NAME" "$ALIYUN_BUCKET" ".env"
        update_env "ALIYUN_OSS_REGION" "$ALIYUN_REGION" ".env"
        update_env "ALIYUN_OSS_ACCESS_KEY_ID" "$ALIYUN_ACCESS_KEY" ".env"
        update_env "ALIYUN_OSS_ACCESS_KEY_SECRET" "$ALIYUN_SECRET_KEY" ".env"
    fi

    if [ "$CONFIGURE_EMAIL" = true ]; then
        update_env "MAIL_TYPE" "smtp" ".env"
        update_env "SMTP_HOST" "$SMTP_HOST" ".env"
        update_env "SMTP_PORT" "$SMTP_PORT" ".env"
        update_env "SMTP_USER" "$SMTP_USER" ".env"
        update_env "SMTP_PASSWORD" "$SMTP_PASSWORD" ".env"
        update_env "MAIL_FROM_ADDRESS" "$SMTP_FROM" ".env"
    fi

    # 设置 .env 文件的权限限制（只有所有者可以读写）
    chmod 600 ".env"
    print_ok "已创建 .env 配置文件"
    echo ""
}

# 检查服务健康状态
check_service_health() {
    local services=$(docker compose ps --format json 2>/dev/null)
    if [ -z "$services" ]; then
        return 1
    fi

    if command -v jq &> /dev/null; then
        # 使用 jq 检查是否有服务不健康/未运行
        if echo "$services" | jq -s 'map(select(.State != "running" and .State != "created")) | length == 0' >/dev/null 2>&1; then
            return 0
        fi
    else
        # 没有 jq 时的简单检查 - 计算不健康的服务数
        local unhealthy=$(docker compose ps 2>/dev/null | grep -v "NAME" | grep -v -E "Up\s+\(healthy\)|Up\s+\(starting\)|Up|running|created" | wc -l)
        if [ "$unhealthy" -eq 0 ]; then
            return 0
        fi
    fi
    return 1
}

# 检查 API 是否响应
check_api_health() {
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        # 尝试连接 API 健康检查端点
        if curl -sf "http://localhost:${HTTP_PORT}/health" >/dev/null 2>&1; then
            return 0
        fi

        # 如果 nginx 未就绪，也尝试直接连接 API 端口
        if curl -sf "http://localhost:5001/health" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
        attempt=$((attempt + 1))
    done

    return 1
}

# 启动服务（带适当的错误处理和健康检查）
start_services() {
    echo "正在启动 Dify..."
    print_step "拉取镜像（可能需要几分钟）..."

    local pull_max_retries=3
    local pull_retry=0
    local pull_success=false

    while [ $pull_retry -lt $pull_max_retries ]; do
        if docker compose pull 2>&1; then
            pull_success=true
            break
        fi

        pull_retry=$((pull_retry + 1))
        if [ $pull_retry -lt $pull_max_retries ]; then
            print_warn "拉取失败，正在重试 ($pull_retry/$pull_max_retries)..."
            sleep 5
        fi
    done

    if [ "$pull_success" = false ]; then
        print_error "镜像拉取失败，已重试 $pull_max_retries 次"
        echo ""
        echo "可能的原因："
        echo "  - 网络连接问题"
        echo "  - Docker Hub 访问限制"
        echo "  - 磁盘空间不足"
        echo ""
        echo "解决方案："
        echo "  - 检查网络连接"
        echo "  - 等待几分钟后重试"
        echo "  - 配置 Docker 镜像加速器"
        echo ""
        echo "如果自托管太复杂，可以尝试 Dify 云服务："
        echo "  https://cloud.dify.ai"
        exit 1
    fi
    print_ok "镜像拉取成功"

    print_step "启动容器..."
    if ! docker compose up -d; then
        print_error "启动容器失败"
        echo ""
        echo "查看日志了解详情："
        echo "  docker compose logs"
        echo ""
        echo "常见问题："
        echo "  - 端口冲突（检查端口 80/443 是否被占用）"
        echo "  - 内存不足（需要至少 4GB）"
        echo "  - 权限问题（确保 Docker 有访问权限）"
        echo ""
        echo "如果自托管太复杂，可以尝试 Dify 云服务："
        echo "  https://cloud.dify.ai"
        exit 1
    fi
    print_ok "容器已启动"

    print_step "等待服务就绪..."
    local max_wait=180
    local waited=0
    local healthy=false

    while [ $waited -lt $max_wait ]; do
        if check_service_health; then
            healthy=true
            break
        fi
        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done
    echo ""

    if [ "$healthy" = true ]; then
        print_ok "所有容器正在运行"
    else
        print_warn "部分容器可能仍在启动中"
        echo "  请使用 docker compose ps 检查状态"
    fi

    # 额外的 API 健康检查
    print_step "验证 API 是否响应..."
    if check_api_health; then
        print_ok "API 健康且响应正常"
    else
        print_warn "API 健康检查超时"
        echo "  服务可能仍在初始化中。使用以下命令查看日志：docker compose logs -f api"
        echo "  如果问题持续，请检查 .env 文件中的配置"
    fi
    echo ""
}

# 主安装流程
main() {
    # 配置 Docker 镜像加速
    configure_docker_mirror

    if [ "$INTERACTIVE" = true ]; then
        interactive_config
        check_prerequisites
        check_ports
    else
        print_header
        check_prerequisites
        check_ports
        echo "使用所有推荐默认值（非交互模式）"
        echo ""
        if [ "$YES_MODE" = false ]; then
            read -p "继续安装？[y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "安装已取消。"
                exit 0
            fi
            echo ""
        fi
    fi

    generate_secrets
    create_env_file
    start_services
    print_success
}

# ============================================
# 函数定义结束
# ============================================

# 解析命令行参数（在所有函数定义之后）
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interactive|-i) INTERACTIVE=true; YES_MODE=false; shift ;;
        --yes|-y|--default) YES_MODE=true; INTERACTIVE=false; shift ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "未知选项: $1"; show_help; exit 1 ;;
    esac
done

# 运行安装
main
