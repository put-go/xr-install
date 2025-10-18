#!/bin/bash

#================================================================
# XrayR 自动化安装配置脚本
# 功能：安装 XrayR、配置审计规则、系统优化、网络加速
# 支持：Ubuntu/Debian/CentOS/Alpine
#================================================================

set -e # 遇到错误立即退出

echo "========================================="
echo " XrayR 自动化安装配置脚本"
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

check_root

# 检测操作系统
OS_TYPE=$(detect_os)
log_info "检测到操作系统: $OS_TYPE"

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
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y curl wget bc vim net-tools >/dev/null 2>&1
        ;;
    centos|rhel|fedora)
        yum install -y curl wget bc vim net-tools >/dev/null 2>&1
        ;;
    alpine)
        apk add --no-cache curl wget bc bash vim net-tools >/dev/null 2>&1
        ;;
    *)
        log_warn "未知系统类型，尝试继续..."
        ;;
esac

log_info "依赖安装完成"

# ============================================
# 步骤 1: 系统内核优化 (BBR + 网络优化)
# ============================================
if [ "$OS_TYPE" != "alpine" ]; then
    log_step "1. 系统内核优化..."
    log_info "配置系统内核参数..."

    # 备份原配置
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)
        log_info "已备份原配置到 /etc/sysctl.conf.bak.*"
    fi

    # 写入优化配置
    cat > /etc/sysctl.conf << 'EOF'
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

    # 应用配置
    log_info "应用内核参数..."
    sysctl -p >/dev/null 2>&1

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
else
    log_step "1. 跳过内核优化 (Alpine 系统)"
    log_info "Alpine 系统使用精简内核，跳过内核优化步骤"
fi

# ============================================
# 步骤 2: 安装 XrayR
# ============================================
log_step "2. 安装 XrayR..."

if [ "$OS_TYPE" = "alpine" ]; then
    log_info "检测到 Alpine 系统，安装 Alpine 专用版本..."
    if wget -N -O alpine-xrayr-install.sh https://raw.githubusercontent.com/put-go/alpineXrayR/refs/heads/main/XrayR_Alpine/install-xrayr.sh 2>/dev/null; then
        chmod +x alpine-xrayr-install.sh
        bash alpine-xrayr-install.sh
        rm -f alpine-xrayr-install.sh
        log_info "Alpine XrayR 安装完成"
    else
        log_error "Alpine XrayR 安装脚本下载失败"
        exit 1
    fi
else
    log_info "安装标准版 XrayR..."
    if wget -N -O xrayr-install.sh https://raw.githubusercontent.com/put-go/XrayR-release/refs/heads/master/install.sh 2>/dev/null; then
        bash xrayr-install.sh
        rm -f xrayr-install.sh
        log_info "XrayR 安装完成"
    else
        log_error "XrayR 安装脚本下载失败"
        exit 1
    fi
fi

# ============================================
# 步骤 3: 安装 GOST (仅非 Alpine 系统)
# ============================================
if [ "$OS_TYPE" != "alpine" ]; then
    log_step "3. 安装 GOST..."
    log_info "开始安装 GOST..."

    # 临时禁用 set -e 避免 GOST 安装脚本的退出码影响
    set +e
    bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh)
    GOST_EXIT_CODE=$?
    set -e

    if [ $GOST_EXIT_CODE -eq 0 ]; then
        log_info "✓ GOST 安装完成"

        # 检查 GOST 是否可用
        if command -v gost >/dev/null 2>&1; then
            GOST_VERSION=$(gost -V 2>/dev/null \vert{} head -n 1 \vert{}\vert{} echo "未知版本")
            log_info "GOST 版本: $GOST_VERSION"
        fi

        # 创建 GOST 配置目录
        log_info "创建 GOST 配置目录..."
        mkdir -p /etc/gost

        # 创建 GOST 示例配置文件
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
        fi

        # 创建 systemd 服务文件
        log_info "创建 GOST systemd 服务..."
        cat > /etc/systemd/system/gost.service << 'SERVICEEOF'
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

        # 重载 systemd
        log_info "配置 GOST 服务..."
        systemctl daemon-reload
        log_info "✓ GOST 服务文件已创建"
        log_info "提示: 修改配置后使用 'systemctl start gost' 启动服务"
        log_info "提示: 设置开机自启: 'systemctl enable gost'"
    else
        log_warn "GOST 安装可能失败（退出码: $GOST_EXIT_CODE），请手动检查"
    fi
else
    log_step "3. 跳过 GOST 安装 (Alpine 系统)"
    log_info "Alpine 系统不安装 GOST"
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

    for url in "${urls[@]}"; do
        if curl -fsSL "$url" -o /etc/XrayR/geosite.dat 2>/dev/null; then
            cp /etc/XrayR/geosite.dat /etc/V2bX/geosite.dat
            log_info "GeoSite 规则文件下载完成"
            return 0
        fi
    done

    log_warn "所有源均下载失败，请手动下载 geosite.dat"
    return 1
}

download_geosite

# 下载 GeoIP 文件
log_info "下载 GeoIP 规则文件..."
if curl -fsSL "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" -o /etc/XrayR/geoip.dat 2>/dev/null; then
    cp /etc/XrayR/geoip.dat /etc/V2bX/geoip.dat
    log_info "GeoIP 规则文件下载完成"
fi

# ============================================
# 步骤 6: 配置审计规则
# ============================================
log_step "6. 配置审计规则..."
sleep 2 # 等待配置文件生成

if ls /etc/XrayR*/config.yml 1> /dev/null 2>&1; then
    sed -i 's|RuleListPath: # /etc/XrayR/rulelist.*|RuleListPath: /etc/XrayR/rulelist|' /etc/XrayR*/config.yml 2>/dev/null || true

    if wget -N https://raw.githubusercontent.com/put-go/blockList/main/blockList -O /etc/XrayR/rulelist 2>/dev/null; then
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
log_step "7. 配置 Vim 编辑器..."
touch ~/.vimrc

for config in "set mouse-=a" "set paste" "syntax on"; do
    if ! grep -q "^$config" ~/.vimrc 2>/dev/null; then
        echo "$config" >> ~/.vimrc
    fi
done

log_info "Vim 配置完成"

# ============================================
# 步骤 8: 性能测试（可选）
# ============================================
log_step "8. 性能测试..."
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

# ============================================
# 步骤 9: 设置命令快捷方式
# ============================================
# log_step "9. 设置命令快捷方式..."
# log_info "设置命令快捷方式..."

# if curl -o /usr/bin/XrayR -Ls https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/XrayR.sh 2>/dev/null; then
#     chmod +x /usr/bin/XrayR
#     ln -sf /usr/bin/XrayR /usr/bin/xrayr
#     log_info "命令快捷方式设置完成"
#     log_info "现在可以使用 'XrayR' 或 'xrayr' 命令管理服务"
# else
#     log_warn "快捷方式脚本下载失败"
# fi

# ============================================
# 步骤 10: 清理临时文件
# ============================================
log_step "10. 清理临时文件..."
rm -f install.sh FastBench.sh install-xrayr.sh alpine-xrayr-install.sh xrayr-install.sh fastbench.sh
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
echo " • 操作系统: $OS_TYPE"
echo " • 主机名: $HOSTNAME"

# 获取 BBR 和 IPv6 状态（仅非 Alpine）
if [ "$OS_TYPE" != "alpine" ]; then
    BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "未知")
    IPV6_STATUS=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}' || echo "未知")
    echo " • BBR 状态: $BBR_STATUS"
    echo " • IPv6 禁用: $IPV6_STATUS"
else
    echo " • 内核优化: 已跳过 (Alpine 系统)"
fi

# 检查已安装的服务
echo ""
echo -e "${BLUE}已安装服务：${NC}"

if command -v XrayR >/dev/null 2>&1 || [ -f /etc/XrayR/config.yml ]; then
    echo "  ✓ XrayR"
    if [ "$OS_TYPE" = "alpine" ]; then
        echo "    版本: Alpine 专用版"
        if rc-service xrayr status >/dev/null 2>&1; then
            echo "    状态: 运行中"
        else
            echo "    状态: 未运行"
        fi
    else
        if systemctl is-active --quiet XrayR 2>/dev/null; then
            echo "    状态: 运行中"
        else
            echo "    状态: 未运行"
        fi
    fi
fi

if [ "$OS_TYPE" != "alpine" ] && command -v gost >/dev/null 2>&1; then
    GOST_VER=$(gost -V 2>/dev/null | head -n 1 || echo "已安装")
    echo "  ✓ GOST ($GOST_VER)"
    if systemctl is-active --quiet gost 2>/dev/null; then
        echo "    状态: 运行中"
    elif systemctl is-enabled --quiet gost 2>/dev/null; then
        echo "    状态: 已启用（未运行）"
    else
        echo "    状态: 未启用"
    fi
fi

# 配置文件位置
echo ""
echo -e "${BLUE}配置文件位置：${NC}"
echo " • XrayR 配置: /etc/XrayR/config.yml"
echo " • 审计规则: /etc/XrayR/rulelist"
echo " • GeoSite: /etc/XrayR/geosite.dat"
echo " • GeoIP: /etc/XrayR/geoip.dat"
if [ "$OS_TYPE" != "alpine" ] && [ -f /etc/gost/gost.yaml ]; then
    echo " • GOST 配置: /etc/gost/gost.yaml"
fi

# 常用命令提示
echo ""
echo -e "${BLUE}常用命令：${NC}"

if [ "$OS_TYPE" = "alpine" ]; then
    echo " • XrayR 管理 (Alpine):"
    echo "   - 启动服务: rc-service xrayr start"
    echo "   - 停止服务: rc-service xrayr stop"
    echo "   - 重启服务: rc-service xrayr restart"
    echo "   - 查看状态: rc-service xrayr status"
    echo "   - 查看日志: cat /var/log/xrayr/xrayr.log"
    echo "   - 开机自启: rc-update add xrayr default"
    echo " • 编辑配置: vi /etc/XrayR/config.yml"
else
    echo " • XrayR 管理: XrayR 或 xrayr"
    echo " • 启动服务: systemctl start XrayR"
    echo " • 停止服务: systemctl stop XrayR"
    echo " • 重启服务: systemctl restart XrayR"
    echo " • 查看状态: systemctl status XrayR"
    echo " • 查看日志: XrayR log 或 journalctl -u XrayR -f"
    echo " • 编辑配置: vim /etc/XrayR/config.yml"
fi

if [ "$OS_TYPE" != "alpine" ] && command -v gost >/dev/null 2>&1; then
    echo ""
    echo -e "${BLUE}GOST 使用：${NC}"
    echo " • 查看版本: gost -V"
    echo " • 查看帮助: gost -h"
    echo " • 示例转发: gost -L=:8080 -F=proxy_server:port"
    echo ""
    echo -e "${BLUE}GOST 服务管理：${NC}"
    echo " • 启动服务: systemctl start gost"
    echo " • 停止服务: systemctl stop gost"
    echo " • 重启服务: systemctl restart gost"
    echo " • 查看状态: systemctl status gost"
    echo " • 查看日志: journalctl -u gost -f"
    echo " • 编辑配置: vim /etc/gost/gost.yaml"
fi

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}脚本执行完成！请根据实际需求修改配置文件${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""

echo -e "${YELLOW}提示:${NC}"
if [ "$OS_TYPE" = "alpine" ]; then
    echo -e "${YELLOW} • Alpine 系统已跳过内核优化步骤${NC}"
    echo -e "${YELLOW} • Alpine 系统已安装 XrayR Alpine 专用版本${NC}"
    echo -e "${YELLOW} • Alpine 系统未安装 GOST（不支持）${NC}"
    echo -e "${YELLOW} • XrayR 配置: vi /etc/XrayR/config.yml${NC}"
else
    echo -e "${YELLOW} • XrayR 配置: vim /etc/XrayR/config.yml${NC}"
    if [ -f /etc/gost/gost.yaml ]; then
        echo -e "${YELLOW} • GOST 配置: vim /etc/gost/gost.yaml (配置后执行 systemctl restart gost)${NC}"
    fi
    echo -e "${YELLOW} • 系统已启用 BBR 加速和网络优化${NC}"
fi

echo ""
exit 0