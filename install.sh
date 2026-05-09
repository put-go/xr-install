#!/bin/bash

#================================================================
# XrayR 自动化安装配置脚本
# 功能：安装 XrayR、GOST、配置审计规则、系统优化、网络加速
#================================================================

set -e  # 遇到错误立即退出

echo "========================================="
echo "  XrayR 自动化安装配置脚本"
echo "========================================="

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

file_contains() {
    local file="$1"
    local text="$2"
    [ -f "$file" ] && grep -Fqx "$text" "$file" 2>/dev/null
}

install_packages_if_missing() {
    local missing=()
    local item
    local pkg
    local cmd

    for item in "$@"; do
        pkg="${item%%:*}"
        cmd="${item#*:}"
        [ "$pkg" = "$cmd" ] && cmd="$pkg"

        if ! command_exists "$cmd"; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log_info "依赖已存在，跳过安装"
        return 0
    fi

    log_info "安装缺失依赖: ${missing[*]}"
    case $OS_TYPE in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y "${missing[@]}" >/dev/null 2>&1
            ;;
        centos|rhel|fedora)
            yum install -y "${missing[@]}" >/dev/null 2>&1
            ;;
        alpine)
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1
            ;;
        *)
            log_warn "未知系统类型，无法自动安装依赖: ${missing[*]}"
            return 1
            ;;
    esac
}

ensure_file_content() {
    local file="$1"
    local content="$2"

    mkdir -p "$(dirname "$file")"

    if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
        return 1
    fi

    if [ -f "$file" ]; then
        cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    printf "%s" "$content" > "$file"
    return 0
}

download_if_missing() {
    local target="$1"
    shift
    local urls=("$@")
    local url

    if [ -s "$target" ]; then
        log_info "$(basename "$target") 已存在，跳过下载"
        return 0
    fi

    for url in "${urls[@]}"; do
        if curl -fsSL "$url" -o "$target" 2>/dev/null; then
            log_info "$(basename "$target") 下载完成"
            return 0
        fi
    done

    return 1
}

download_with_overwrite() {
    local target="$1"
    shift
    local urls=("$@")
    local url

    for url in "${urls[@]}"; do
        if curl -fsSL "$url" -o "$target" 2>/dev/null; then
            log_info "$(basename "$target") 已更新"
            return 0
        fi
    done

    return 1
}

configure_chrony_for_kvm() {
    if [ "$VIRT_TYPE" != "kvm" ]; then
        return 0
    fi

    log_step "KVM 环境配置 chrony 时间同步..."

    case $OS_TYPE in
        ubuntu|debian)
            install_packages_if_missing chrony:chronyd || true
            CHRONY_CONF="/etc/chrony/chrony.conf"
            CHRONY_SERVICE="chrony"
            ;;
        centos|rhel|fedora)
            install_packages_if_missing chrony:chronyd || true
            CHRONY_CONF="/etc/chrony.conf"
            CHRONY_SERVICE="chronyd"
            ;;
        alpine)
            install_packages_if_missing chrony:chronyd || true
            CHRONY_CONF="/etc/chrony/chrony.conf"
            CHRONY_SERVICE="chronyd"
            ;;
        *)
            log_warn "当前系统暂未适配 chrony 自动配置，跳过时间同步设置"
            return 0
            ;;
    esac

    CHRONY_CONTENT=$(cat << 'EOF'
server ntp.aliyun.com iburst
server ntp.tencent.com iburst
server time.cloudflare.com iburst

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync

logdir /var/log/chrony
EOF
)

    if ensure_file_content "$CHRONY_CONF" "$CHRONY_CONTENT"; then
        log_info "chrony 配置已更新"
    else
        log_info "chrony 配置无变化，跳过重写"
    fi

    if [ "$OS_TYPE" = "alpine" ]; then
        if ! rc-update show 2>/dev/null | grep -q "^ *chronyd"; then
            rc-update add chronyd default >/dev/null 2>&1 || true
        fi
        if ! rc-service chronyd status 2>/dev/null | grep -q "started"; then
            rc-service chronyd start >/dev/null 2>&1 || true
        fi
    else
        if ! systemctl is-enabled --quiet "$CHRONY_SERVICE" 2>/dev/null || ! systemctl is-active --quiet "$CHRONY_SERVICE" 2>/dev/null; then
            systemctl enable --now "$CHRONY_SERVICE" >/dev/null 2>&1 || {
                systemctl enable "$CHRONY_SERVICE" >/dev/null 2>&1 || true
                systemctl start "$CHRONY_SERVICE" >/dev/null 2>&1 || systemctl restart "$CHRONY_SERVICE" >/dev/null 2>&1 || true
            }
        fi
    fi

    if command -v chronyc >/dev/null 2>&1; then
        chronyc -a makestep >/dev/null 2>&1 || true
    fi

    log_info "KVM 环境 chrony 时间同步配置完成"
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        OS=$(uname -s)
    fi
    echo $OS
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户或 sudo 执行此脚本"
        exit 1
    fi
}

# 配置 Vim 编辑器的独立函数
configure_vim() {
    log_step "配置 Vim 编辑器..."
    
    touch ~/.vimrc
    for config in "set mouse-=a" "set paste" "syntax on" ; do
        if ! grep -q "^$config" ~/.vimrc 2>/dev/null; then
            echo "$config" >> ~/.vimrc
        fi
    done
    log_info "Vim 配置完成"
    
    echo ""
    echo -e "${GREEN}Vim 配置已应用：${NC}"
    echo "  • 禁用鼠标模式"
    echo "  • 启用粘贴模式"
    echo "  • 启用语法高亮"
    echo ""
    echo -e "${BLUE}配置文件位置：${NC} ~/.vimrc"
    echo ""
}

# 检查服务器配置（CPU 和 内存）
check_server_specs() {
    # 获取 CPU 核心数
    CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
    
    # 获取内存大小（MB）
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    
    # 转换为 GB（向下取整）
    MEM_GB=$(echo "scale=0; $TOTAL_MEM / 1024" | bc)
    
    log_info "检测到服务器配置: ${CPU_CORES}核 CPU, ${MEM_GB}GB 内存 (${TOTAL_MEM}MB)"
    
    # 判断是否低于 1C1G
    if [ "$CPU_CORES" -lt 1 ] || [ "$MEM_GB" -lt 1 ]; then
        return 1  # 配置不足
    else
        return 0  # 配置充足
    fi
}

# 处理命令行参数
if [ "$1" = "--vim" ] || [ "$1" = "-v" ]; then
    check_root
    configure_vim
    exit 0
fi

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --vim, -v     仅配置 Vim 编辑器"
    echo "  --help, -h    显示此帮助信息"
    echo ""
    echo "不带参数运行将执行完整安装流程"
    exit 0
fi

check_root

# 检测系统类型（提前检测）
OS_TYPE=$(detect_os)
log_info "检测到系统类型: $OS_TYPE"

# 检测虚拟化类型
VIRT_TYPE="none"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
    log_info "检测到虚拟化类型: $VIRT_TYPE"
fi

# ============================================
# 步骤 0: 系统初始化
# ============================================
log_step "0. 系统初始化..."

# 修复 hostname 问题
log_info "修复主机名解析..."
HOSTNAME=$(hostname)
if ! grep -q "127.0.0.1.*$HOSTNAME" /etc/hosts; then
    sed -i "/127.0.0.1.*localhost/a 127.0.0.1 $HOSTNAME" /etc/hosts
    log_info "已添加主机名到 /etc/hosts"
fi

# 安装必要的依赖
log_info "检查并安装必要的依赖..."

case $OS_TYPE in
    ubuntu|debian)
        install_packages_if_missing curl wget bc vim net-tools:netstat
        ;;
    centos|rhel|fedora)
        install_packages_if_missing curl wget bc vim net-tools:netstat
        ;;
    alpine)
        install_packages_if_missing curl wget bc bash vim openrc:rc-service
        ;;
    *)
        log_warn "未知系统类型，尝试继续..."
        ;;
esac
log_info "依赖安装完成"

configure_chrony_for_kvm

# ============================================
# 步骤 1: 系统内核优化 (BBR + 网络优化)
# Alpine 系统和 LXC 容器跳过此步骤
# ============================================
if [ "$OS_TYPE" = "alpine" ] || [ "$VIRT_TYPE" = "lxc" ]; then
    log_step "1. 跳过系统内核优化"
    if [ "$OS_TYPE" = "alpine" ]; then
        log_info "Alpine 系统使用轻量级设计，无需内核优化"
    fi
    if [ "$VIRT_TYPE" = "lxc" ]; then
        log_info "LXC 容器环境，内核参数由宿主机管理"
    fi
    log_info "默认配置已足够满足 XrayR 运行需求"
else
    log_step "1. 系统内核优化..."

    log_info "配置系统内核参数..."
    if true; then

        SYSCTL_CONTENT=$(cat << 'EOF'
# ============================================
# XrayR 系统优化配置
# ============================================
# 文件系统优化
fs.file-max = 6815744

# TCP 基础优化
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# TCP 快速打开
net.ipv4.tcp_fastopen = 3

# TCP 连接优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 8192

# TCP 连接复用
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 30

# 网络缓冲区（32MB）
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 网络队列优化
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192

# IPv4 转发
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# 拥塞控制 BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 永久禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
)

        if ensure_file_content "/etc/sysctl.conf" "$SYSCTL_CONTENT"; then
            log_info "系统参数已更新，应用内核参数..."
            sysctl -p >/dev/null 2>&1
            sysctl --system >/dev/null 2>&1
        else
            log_info "系统参数无变化，跳过重复写入"
        fi

        # 验证 BBR
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            log_info "✓ BBR 加速已启用"
        else
            log_warn "BBR 启用失败，可能需要更新内核"
        fi

        # 验证 IPv6
        if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "= 1"; then
            log_info "✓ IPv6 已禁用"
        fi

        log_info "系统内核优化完成"
    fi
fi

# ============================================
# 步骤 2: 安装 XrayR
# ============================================
log_step "2. 安装 XrayR..."

if [ "$OS_TYPE" = "alpine" ]; then
    # Alpine 系统使用专用安装脚本
    if [ -f /etc/XrayR/config.yml ] || [ -f /etc/init.d/XrayR ]; then
        log_info "检测到 XrayR 已安装，跳过重复安装"
    else
        log_info "使用 Alpine 专用 XrayR 安装脚本..."
        if wget -O alpine-xrayr-install.sh https://raw.githubusercontent.com/put-go/alpineXrayR/refs/heads/main/XrayR_Alpine/install-xrayr.sh 2>/dev/null; then
        chmod +x alpine-xrayr-install.sh
        
        # 临时禁用错误退出
        set +e
        bash alpine-xrayr-install.sh
        XRAYR_EXIT_CODE=$?
        set -e
        
        rm -f alpine-xrayr-install.sh
        
            if [ $XRAYR_EXIT_CODE -eq 0 ]; then
                log_info "Alpine XrayR 安装完成"
            else
                log_warn "Alpine XrayR 安装可能存在问题（退出码: $XRAYR_EXIT_CODE）"
            fi
        else
            log_error "Alpine XrayR 安装脚本下载失败"
            exit 1
        fi
    fi
else
    # 非 Alpine 系统使用标准安装脚本
    if [ -f /etc/XrayR/config.yml ] || systemctl list-unit-files 2>/dev/null | grep -q "^XrayR.service"; then
        log_info "检测到 XrayR 已安装，跳过重复安装"
    else
        log_info "使用标准 XrayR 安装脚本..."
        if wget -O xrayr-install.sh https://raw.githubusercontent.com/put-go/XrayR-release/refs/heads/master/install.sh 2>/dev/null; then
            bash xrayr-install.sh
            rm -f xrayr-install.sh
            log_info "XrayR 安装完成"
        else
            log_error "XrayR 安装脚本下载失败"
            exit 1
        fi
    fi
fi

# ============================================
# 步骤 3: 安装 GOST（仅非 Alpine 系统）
# ============================================
if [ "$OS_TYPE" != "alpine" ]; then
    log_step "3. 安装 GOST..."

    read -p "是否安装 GOST？(y/n，默认n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if command -v gost >/dev/null 2>&1; then
            log_info "检测到 GOST 已安装，跳过重复安装"
        else
            log_info "开始安装 GOST..."

            # 临时禁用 set -e 避免 GOST 安装脚本的退出码影响
            set +e
            bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh)
            GOST_EXIT_CODE=$?
            set -e

            if [ $GOST_EXIT_CODE -eq 0 ]; then
                log_info "✓ GOST 安装完成"
            else
                log_warn "GOST 安装可能失败（退出码: $GOST_EXIT_CODE），请手动检查"
            fi
        fi

        if command -v gost >/dev/null 2>&1; then
            GOST_VERSION=$(gost -V 2>/dev/null | head -n 1 || echo "未知版本")
            log_info "GOST 版本: $GOST_VERSION"

            log_info "创建 GOST 配置目录..."
            mkdir -p /etc/gost

            if [ ! -f /etc/gost/gost.yaml ]; then
                log_info "创建 GOST 示例配置文件..."
                cat > /etc/gost/gost.yaml << 'GOSTEOF'
# GOST 配置文件示例
# 请根据实际需求修改此配置

# 服务配置
services:
  - name: service-0
    addr: ":8080"
    handler:
      type: auto
    listener:
      type: tcp
GOSTEOF
                log_info "已创建示例配置: /etc/gost/gost.yaml"
            else
                log_info "GOST 配置已存在，跳过示例配置写入"
            fi

            GOST_SERVICE_CONTENT=$(cat << 'SERVICEEOF'
[Unit]
Description=Gost Proxy Service
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/etc/gost
ExecStart=/usr/local/bin/gost -C /etc/gost/gost.yaml
StandardOutput=null
StandardError=null
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICEEOF
)

            if ensure_file_content "/etc/systemd/system/gost.service" "$GOST_SERVICE_CONTENT"; then
                log_info "配置 GOST 服务..."
                systemctl daemon-reload
                log_info "✓ GOST 服务文件已更新"
            else
                log_info "GOST 服务文件无变化，跳过重写"
            fi
            log_warn "注意: GOST 未启动也未设置开机自启"
            log_info "提示: 修改配置后使用以下命令管理："
            log_info "  • 启动服务: systemctl start gost"
            log_info "  • 设置开机自启: systemctl enable gost"
            log_info "  • 同时启动并开机自启: systemctl enable --now gost"
        fi
    else
        log_info "已跳过 GOST 安装"
    fi
else
    log_step "3. 跳过 GOST 安装（Alpine 系统不支持）"
    log_info "检测到 Alpine 系统，GOST 安装已跳过"
    log_info "Alpine 系统可使用其他轻量级代理工具"
fi

# ============================================
# 步骤 4: 创建配置目录
# ============================================
log_step "4. 创建配置目录..."
mkdir -p /etc/XrayR/ /etc/V2bX/
log_info "配置目录创建完成"

# ============================================
# 步骤 5: 下载 GeoSite 规则
# ============================================
log_step "5. 下载 GeoSite 规则文件..."

download_geosite() {
    local urls=(
        "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
        "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat"
    )

    if download_if_missing "/etc/XrayR/geosite.dat" "${urls[@]}"; then
        cp /etc/XrayR/geosite.dat /etc/V2bX/geosite.dat
        return 0
    fi

    log_warn "所有源均下载失败，请手动下载 geosite.dat"
    return 1
}

download_geosite

# 下载 GeoIP 文件
log_info "下载 GeoIP 规则文件..."
if download_if_missing "/etc/XrayR/geoip.dat" "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"; then
    cp /etc/XrayR/geoip.dat /etc/V2bX/geoip.dat
fi

# ============================================
# 步骤 6: 配置审计规则
# ============================================
log_step "6. 配置审计规则..."

sleep 2  # 等待配置文件生成
if ls /etc/XrayR*/config.yml 1> /dev/null 2>&1; then
    sed -i 's|RuleListPath: # /etc/XrayR/rulelist.*|RuleListPath: /etc/XrayR/rulelist|' /etc/XrayR*/config.yml 2>/dev/null || true

    if download_with_overwrite "/etc/XrayR/rulelist" "https://raw.githubusercontent.com/put-go/blockList/main/blockList"; then
        log_info "审计规则配置完成"
    else
        log_warn "审计规则下载失败"
    fi
else
    log_warn "配置文件不存在，跳过审计规则设置"
fi

# ============================================
# 步骤 7: 配置 Vim 编辑器
# ============================================
configure_vim

# ============================================
# 步骤 8: 性能测试（可选）
# Alpine 系统跳过性能测试
# ============================================
if [ "$OS_TYPE" = "alpine" ]; then
    log_step "8. 跳过性能测试（Alpine 系统）"
    log_info "Alpine 系统通常用于容器环境，跳过性能测试"
    log_info "如需测试，可手动运行性能测试脚本"
else
    log_step "8. 性能测试..."

    # 检查服务器配置
    if check_server_specs; then
        read -p "是否进行服务器性能测试？(y/n，默认n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "开始性能测试..."

            if wget -N -O fastbench.sh http://raw.githubusercontent.com/sshpc/FastBench/main/FastBench.sh 2>/dev/null; then
                chmod +x fastbench.sh

                # 临时禁用错误立即退出
                set +e
                bash fastbench.sh
                BENCH_EXIT_CODE=$?
                set -e

                # 友好的退出码处理
                case $BENCH_EXIT_CODE in
                    0)
                        log_info "✓ 性能测试完成"
                        ;;
                    1)
                        log_info "✓ 性能测试完成（含警告）"
                        ;;
                    *)
                        log_warn "性能测试异常退出（退出码: $BENCH_EXIT_CODE），可继续"
                        ;;
                esac

                rm -f fastbench.sh
            else
                log_warn "性能测试脚本下载失败，跳过此步骤"
            fi
        else
            log_info "已跳过性能测试"
        fi
    else
        log_warn "检测到服务器配置低于 1C1G，自动跳过性能测试"
        log_info "提示: 如需强制测试，可手动运行:"
        log_info "  wget -O - http://raw.githubusercontent.com/sshpc/FastBench/main/FastBench.sh | bash"
    fi
fi

# ============================================
# 步骤 9: 安装 Nezha 监控探针（可选）
# ============================================
log_step "9. 安装监控探针..."

read -p "是否安装 Nezha 监控探针？(y/n，默认n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "开始安装 Nezha 监控探针..."

    # 提示用户输入服务器信息
    echo ""
    echo -e "${YELLOW}请输入 Nezha 服务器信息（直接回车使用默认值）：${NC}"
    read -p "服务器地址 [默认: nz.supergene.top:443]: " NZ_SERVER_INPUT
    read -p "客户端密钥 [默认: BVvcAVXU5mBNgmYt3uyckSTAX3HxoiEJ]: " NZ_SECRET_INPUT

    # 使用用户输入或默认值
    NZ_SERVER=${NZ_SERVER_INPUT:-"nz.supergene.top:443"}
    NZ_CLIENT_SECRET=${NZ_SECRET_INPUT:-"BVvcAVXU5mBNgmYt3uyckSTAX3HxoiEJ"}

    log_info "服务器: $NZ_SERVER"
    log_info "正在下载安装脚本..."

    if curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh 2>/dev/null; then
        chmod +x agent.sh

        # 临时禁用错误立即退出
        set +e
        env NZ_SERVER="$NZ_SERVER" NZ_TLS=true NZ_CLIENT_SECRET="$NZ_CLIENT_SECRET" ./agent.sh
        AGENT_EXIT_CODE=$?
        set -e

        # 清理安装脚本
        rm -f agent.sh

        if [ $AGENT_EXIT_CODE -eq 0 ]; then
            log_info "✓ Nezha 监控探针安装完成"
        else
            log_warn "Nezha 监控探针安装可能存在问题（退出码: $AGENT_EXIT_CODE）"
        fi
    else
        log_error "Nezha 监控探针安装脚本下载失败"
    fi
else
    log_info "已跳过监控探针安装"
fi

# ============================================
# 步骤 10: 设置命令快捷方式
# Alpine 系统使用 OpenRC 直接管理，无需管理脚本
# ============================================
log_step "10. 配置服务管理方式..."

if [ "$OS_TYPE" = "alpine" ]; then
    log_info "Alpine 系统使用 OpenRC 服务管理"
    log_info "XrayR 服务已通过 /etc/init.d/XrayR 配置"
    log_info "使用以下命令管理服务："
    log_info "  • 启动: rc-service XrayR start"
    log_info "  • 停止: rc-service XrayR stop"
    log_info "  • 重启: rc-service XrayR restart"
    log_info "  • 状态: rc-service XrayR status"
    
    # 检查是否已添加到开机启动
    if rc-update show 2>/dev/null | grep -q XrayR; then
        log_info "✓ XrayR 已设置开机自启"
    else
        log_warn "XrayR 未设置开机自启，运行: rc-update add XrayR"
    fi
else
    log_info "配置标准 XrayR 管理命令..."
    if [ -x /usr/bin/XrayR ] && [ -L /usr/bin/xrayr ]; then
        log_info "XrayR 管理命令已存在，跳过重复配置"
    else
        if curl -fSL https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/XrayR.sh -o /usr/bin/XrayR 2>/dev/null; then
            chmod +x /usr/bin/XrayR
            ln -sf /usr/bin/XrayR /usr/bin/xrayr
            log_info "✓ 命令快捷方式设置完成"
            log_info "现在可以使用 'XrayR' 或 'xrayr' 命令管理服务"
        else
            log_warn "管理脚本下载失败，请使用 systemctl 管理"
        fi
    fi
fi

# ============================================
# 步骤 11: 清理临时文件
# ============================================
log_step "11. 清理临时文件..."
rm -f install.sh FastBench.sh xrayr-install.sh alpine-xrayr-install.sh
log_info "临时文件清理完成"

# ============================================
# 完成提示
# ============================================
echo ""
echo "========================================="
log_info "所有操作已完成！"
echo "========================================="
echo ""
echo -e "${BLUE}系统信息：${NC}"
echo "  • 操作系统: $OS_TYPE"
echo "  • 主机名: $HOSTNAME"
if [ "$VIRT_TYPE" != "none" ]; then
    echo "  • 虚拟化: $VIRT_TYPE"
fi

# 仅非 Alpine 系统且非 LXC 容器显示 BBR 和 IPv6 状态
if [ "$OS_TYPE" != "alpine" ] && [ "$VIRT_TYPE" != "lxc" ]; then
    BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "未知")
    IPV6_STATUS=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}' || echo "未知")
    echo "  • BBR 状态: $BBR_STATUS"
    echo "  • IPv6 禁用: $IPV6_STATUS"
else
    if [ "$OS_TYPE" = "alpine" ]; then
        echo "  • 系统优化: 跳过（Alpine 轻量级系统）"
    elif [ "$VIRT_TYPE" = "lxc" ]; then
        echo "  • 系统优化: 跳过（LXC 容器环境）"
    fi
fi

# 检查已安装的服务
echo ""
echo -e "${BLUE}已安装服务：${NC}"

if [ -f /etc/XrayR/config.yml ]; then
    echo "  ✓ XrayR"
    
    # 根据系统类型检查服务状态
    if [ "$OS_TYPE" = "alpine" ]; then
        if [ -f /etc/init.d/XrayR ]; then
            echo "    • 服务文件: /etc/init.d/XrayR"
            
            # 检查服务状态
            if rc-service XrayR status 2>/dev/null | grep -q "started"; then
                echo "    • 运行状态: 运行中"
            else
                echo "    • 运行状态: 未运行"
            fi
            
            # 检查开机自启
            if rc-update show 2>/dev/null | grep -q XrayR; then
                echo "    • 开机自启: 已启用"
            else
                echo "    • 开机自启: 未启用"
            fi
        fi
    else
        if systemctl is-active --quiet XrayR 2>/dev/null; then
            echo "    • 运行状态: 运行中"
        else
            echo "    • 运行状态: 未运行"
        fi
    fi
fi

if command -v gost >/dev/null 2>&1; then
    GOST_VER=$(gost -V 2>/dev/null | head -n 1 || echo "已安装")
    echo "  ✓ GOST ($GOST_VER)"
    if systemctl is-active --quiet gost 2>/dev/null; then
        echo "    • 运行状态: 运行中"
    elif systemctl is-enabled --quiet gost 2>/dev/null; then
        echo "    • 运行状态: 已启用（未运行）"
    else
        echo "    • 运行状态: 未启用（需手动配置并启动）"
    fi
elif [ "$OS_TYPE" = "alpine" ]; then
    echo "  ⊗ GOST (Alpine 系统不支持)"
fi

# 配置文件位置
echo ""
echo -e "${BLUE}配置文件位置：${NC}"
echo "  • XrayR 配置: /etc/XrayR/config.yml"
echo "  • 审计规则: /etc/XrayR/rulelist"
echo "  • GeoSite: /etc/XrayR/geosite.dat"
echo "  • GeoIP: /etc/XrayR/geoip.dat"
if [ -f /etc/gost/gost.yaml ]; then
    echo "  • GOST 配置: /etc/gost/gost.yaml"
fi
echo "  • Vim 配置: ~/.vimrc"

# 常用命令提示
echo ""
echo -e "${BLUE}服务管理命令：${NC}"

if [ "$OS_TYPE" = "alpine" ]; then
    echo "  ${YELLOW}Alpine 使用 OpenRC 管理：${NC}"
    echo "  • 启动服务: rc-service XrayR start"
    echo "  • 停止服务: rc-service XrayR stop"
    echo "  • 重启服务: rc-service XrayR restart"
    echo "  • 查看状态: rc-service XrayR status"
    echo "  • 开机自启: rc-update add XrayR default"
    echo "  • 取消自启: rc-update del XrayR default"
    echo ""
    echo "  ${YELLOW}查看服务：${NC}"
    echo "  • 列出所有服务: rc-status"
    echo "  • 查看启动项: rc-update show"
else
    if command -v XrayR >/dev/null 2>&1 && [ -x /usr/bin/XrayR ]; then
        echo "  ${YELLOW}使用管理脚本：${NC}"
        echo "  • 管理菜单: XrayR"
        echo "  • 启动服务: XrayR start"
        echo "  • 停止服务: XrayR stop"
        echo "  • 重启服务: XrayR restart"
        echo "  • 查看状态: XrayR status"
        echo "  • 查看日志: XrayR log"
        echo ""
    fi
    echo "  ${YELLOW}使用 systemctl：${NC}"
    echo "  • 启动服务: systemctl start XrayR"
    echo "  • 停止服务: systemctl stop XrayR"
    echo "  • 重启服务: systemctl restart XrayR"
    echo "  • 查看状态: systemctl status XrayR"
    echo "  • 开机自启: systemctl enable XrayR"
    echo "  • 取消自启: systemctl disable XrayR"
fi

echo ""
echo -e "${BLUE}配置编辑：${NC}"
echo "  • 编辑配置: vim /etc/XrayR/config.yml"
echo "  • 编辑规则: vim /etc/XrayR/rulelist"

if command -v gost >/dev/null 2>&1; then
    echo ""
    echo -e "${BLUE}GOST 工具：${NC}"
    echo "  • 查看版本: gost -V"
    echo "  • 查看帮助: gost -h"
    echo "  • 编辑配置: vim /etc/gost/gost.yaml"
    echo ""
    echo -e "${BLUE}GOST 服务管理：${NC}"
    echo "  • 启动服务: systemctl start gost"
    echo "  • 停止服务: systemctl stop gost"
    echo "  • 重启服务: systemctl restart gost"
    echo "  • 查看状态: systemctl status gost"
    echo "  • 开机自启: systemctl enable gost"
fi

echo ""
echo -e "${BLUE}脚本特殊参数：${NC}"
echo "  • 单独配置 Vim: bash <(wget -qO- https://raw.githubusercontent.com/put-go/xr-install/refs/heads/master/install.sh) --vim"
echo "  • 查看帮助: bash <(wget -qO- https://raw.githubusercontent.com/put-go/xr-install/refs/heads/master/install.sh) --help"
echo ""

echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}脚本执行完成！请根据实际需求修改配置文件${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""

echo -e "${YELLOW}下一步操作提示:${NC}"
echo -e "${YELLOW}  1. 编辑 XrayR 配置: vim /etc/XrayR/config.yml${NC}"
echo -e "${YELLOW}  2. 配置对接面板信息（ApiHost、ApiKey、NodeID 等）${NC}"

if [ "$OS_TYPE" = "alpine" ]; then
    echo -e "${YELLOW}  3. 启动 XrayR: rc-service XrayR start${NC}"
    echo -e "${YELLOW}  4. 检查状态: rc-service XrayR status${NC}"
    echo -e "${YELLOW}  5. 设置自启: rc-update add XrayR default${NC}"
else
    echo -e "${YELLOW}  3. 启动 XrayR: systemctl start XrayR 或 XrayR start${NC}"
    echo -e "${YELLOW}  4. 检查状态: systemctl status XrayR 或 XrayR status${NC}"
    echo -e "${YELLOW}  5. 设置自启: systemctl enable XrayR${NC}"
fi

if [ -f /etc/gost/gost.yaml ]; then
    echo -e "${YELLOW}  6. GOST 配置: vim /etc/gost/gost.yaml${NC}"
    echo -e "${YELLOW}  7. GOST 启动: systemctl enable --now gost${NC}"
fi

echo ""

# Alpine 系统特别提示
if [ "$OS_TYPE" = "alpine" ]; then
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}Alpine 系统特别说明：${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${YELLOW}  • Alpine 使用轻量级设计，已跳过内核优化${NC}"
    echo -e "${YELLOW}  • Alpine 不支持 GOST，已自动跳过${NC}"
    echo -e "${YELLOW}  • Alpine 使用 OpenRC 管理服务（非 systemd）${NC}"
    echo -e "${YELLOW}  • OpenRC 服务文件: /etc/init.d/XrayR${NC}"
    echo -e "${YELLOW}  • 默认配置已足够满足 XrayR 运行需求${NC}"
    echo ""
    echo -e "${BLUE}OpenRC 常用命令：${NC}"
    echo -e "  • 查看所有服务: ${GREEN}rc-status${NC}"
    echo -e "  • 查看启动项: ${GREEN}rc-update show${NC}"
    echo -e "  • 启动服务: ${GREEN}rc-service XrayR start${NC}"
    echo -e "  • 停止服务: ${GREEN}rc-service XrayR stop${NC}"
    echo -e "  • 重启服务: ${GREEN}rc-service XrayR restart${NC}"
    echo -e "  • 查看状态: ${GREEN}rc-service XrayR status${NC}"
    echo -e "  • 添加自启: ${GREEN}rc-update add XrayR default${NC}"
    echo -e "  • 移除自启: ${GREEN}rc-update del XrayR default${NC}"
    echo ""
fi

exit 0
