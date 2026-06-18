#!/bin/bash
set -e

# ============================================================
# CrowdSec 自动安装脚本（Coolify + Traefik，独立模式）
# 适用于 Debian 系统
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}==== $1 ====${NC}"; }

ACCESS_LOG_PATH="/data/coolify/proxy/accesslogs/access.log"
COMPOSE_FILE="/data/coolify/proxy/docker-compose.yml"
CROWDSEC_REPO_FILE="/etc/apt/sources.list.d/crowdsec_crowdsec.list"
CROWDSEC_CONFIG="/etc/crowdsec/config.yaml"

# ============================================================
# 检查 root
# ============================================================
if [ "$EUID" -ne 0 ]; then
    log_error "请用 root 用户运行此脚本"
    exit 1
fi

# ============================================================
# 检查 access log
# ============================================================
log_section "检查 Traefik Access Log"

check_access_log() {
    if [ -f "$ACCESS_LOG_PATH" ] && [ -s "$ACCESS_LOG_PATH" ]; then
        log_info "Access log 已存在: $ACCESS_LOG_PATH"
        return 0
    else
        return 1
    fi
}

enable_access_log() {
    log_warn "未检测到 Traefik access log"

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "找不到 Coolify Traefik 配置文件: $COMPOSE_FILE"
        log_error "请确认 Coolify 已正确安装"
        exit 1
    fi

    if grep -q "accesslog=true" "$COMPOSE_FILE"; then
        log_warn "compose 文件里已有 accesslog 配置，但日志文件不存在或为空"
        log_warn "请等待 Traefik 产生流量后重新运行脚本"
        exit 1
    fi

    echo ""
    log_warn "需要修改 Traefik 配置以开启 access log"
    log_warn "将在 $COMPOSE_FILE 的 command 段添加以下两行："
    echo ""
    echo "      - '--accesslog=true'"
    echo "      - '--accesslog.filepath=/traefik/accesslogs/access.log'"
    echo ""
    read -rp "确认修改？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_error "已取消，请手动开启 access log 后重新运行脚本"
        exit 1
    fi

    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    log_info "已备份原配置文件"

    sed -i "/--ping\.entrypoint=http/a\\      - '--accesslog.filepath=/traefik/accesslogs/access.log'\n      - '--accesslog=true'" "$COMPOSE_FILE"

    log_info "配置已修改，正在重启 Traefik..."
    cd /data/coolify/proxy && docker compose up -d --force-recreate

    log_info "等待 Traefik 启动..."
    sleep 5

    mkdir -p /data/coolify/proxy/accesslogs

    log_info "等待日志文件生成（最多 30 秒）..."
    for i in $(seq 1 30); do
        if [ -f "$ACCESS_LOG_PATH" ]; then
            log_info "Access log 已生成"
            break
        fi
        sleep 1
        echo -n "."
    done
    echo ""

    if [ ! -f "$ACCESS_LOG_PATH" ]; then
        log_warn "日志文件尚未生成，可能还没有流量进入"
        log_warn "请稍后重新运行脚本，或手动访问服务器上的某个服务后再试"
        exit 1
    fi
}

if ! check_access_log; then
    enable_access_log
fi

# ============================================================
# 添加 CrowdSec 软件源
# ============================================================
log_section "添加 CrowdSec 软件源"

if [ -f "$CROWDSEC_REPO_FILE" ]; then
    log_info "CrowdSec 软件源已存在，跳过"
else
    log_info "添加 CrowdSec 软件源..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    log_info "软件源添加完成"
fi

# ============================================================
# 安装 CrowdSec
# ============================================================
log_section "安装 CrowdSec"

if command -v cscli &>/dev/null; then
    log_info "CrowdSec 已安装，版本: $(cscli version 2>/dev/null | grep 'version:' | awk '{print $2}')"
else
    log_info "安装 CrowdSec..."
    apt install crowdsec -y
    log_info "CrowdSec 安装完成"
fi

# ============================================================
# 确保本地 LAPI 已启用（独立模式必须）
# ============================================================
log_section "检查本地 LAPI 配置"

if grep -q "enable: false" "$CROWDSEC_CONFIG" 2>/dev/null; then
    log_warn "检测到本地 LAPI 被禁用，正在恢复..."
    sed -i 's/enable: false/enable: true/' "$CROWDSEC_CONFIG"
    log_info "本地 LAPI 已启用"
else
    log_info "本地 LAPI 配置正常"
fi

# 强制覆盖凭证文件，确保指向本机 LAPI
MACHINE_NAME=$(hostname)
MACHINE_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
cat > /etc/crowdsec/local_api_credentials.yaml << EOF
url: http://127.0.0.1:8080
login: ${MACHINE_NAME}
password: ${MACHINE_PASS}
EOF
log_info "凭证文件已重置为本机 LAPI"

# 启动 LAPI 后再注册 agent（先重启让 LAPI 起来）
systemctl restart crowdsec
sleep 5

# 重新注册本机 agent
cscli machines delete "${MACHINE_NAME}" 2>/dev/null || true
cscli machines add "${MACHINE_NAME}" -f /etc/crowdsec/local_api_credentials.yaml --force 2>/dev/null || true
log_info "本机 agent 注册完成"

# ============================================================
# 安装 collections
# ============================================================
log_section "安装检测规则"

log_info "安装 Traefik collection..."
cscli collections install crowdsecurity/traefik 2>/dev/null || true

log_info "安装 Linux collection..."
cscli collections install crowdsecurity/linux 2>/dev/null || true

# ============================================================
# 配置 acquis（日志采集）
# ============================================================
log_section "配置日志采集"

mkdir -p /etc/crowdsec/acquis.d

cat > /etc/crowdsec/acquis.d/traefik.yaml << EOF
filenames:
  - /data/coolify/proxy/accesslogs/access.log
labels:
  type: traefik
EOF
log_info "Traefik acquis 配置完成"

# ============================================================
# 配置白名单
# ============================================================
log_section "配置白名单"

WHITELIST_FILE="/etc/crowdsec/parsers/s02-enrich/whitelists.yaml"

echo ""
log_info "请输入需要加入白名单的 IP（你的家庭/办公室 IP、控制面板服务器 IP 等）"
log_info "每行输入一个 IP，输入空行结束："
echo ""

WHITELIST_IPS=()
while true; do
    read -rp "  IP: " ip
    if [ -z "$ip" ]; then
        break
    fi
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        WHITELIST_IPS+=("$ip")
        log_info "已添加: $ip"
    else
        log_warn "无效的 IP 格式，跳过: $ip"
    fi
done

{
    echo "name: crowdsecurity/whitelists"
    echo "description: \"Whitelist trusted IPs\""
    echo "whitelist:"
    echo "  reason: \"trusted IPs and private ranges\""
    echo "  ip:"
    for ip in "${WHITELIST_IPS[@]}"; do
        echo "    - \"${ip}\""
    done
    echo "  cidr:"
    echo "    - \"127.0.0.0/8\""
    echo "    - \"10.0.0.0/8\""
    echo "    - \"172.16.0.0/12\""
    echo "    - \"192.168.0.0/16\""
} > "$WHITELIST_FILE"

if [ ${#WHITELIST_IPS[@]} -eq 0 ]; then
    log_warn "未配置白名单 IP，只保留私有网段白名单"
else
    log_info "白名单配置完成，共添加 ${#WHITELIST_IPS[@]} 个 IP"
fi

# ============================================================
# 等待 LAPI 就绪
# ============================================================
log_section "启动 CrowdSec"

# 验证 LAPI 是否正常
if ! cscli lapi status &>/dev/null; then
    log_error "LAPI 启动失败，请检查: journalctl -u crowdsec -n 50"
    exit 1
fi
log_info "LAPI 运行正常"

# ============================================================
# 安装 Firewall Bouncer
# ============================================================
log_section "安装 Firewall Bouncer"

if systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null; then
    log_info "Firewall bouncer 已安装并运行"
else
    log_info "安装 crowdsec-firewall-bouncer..."
    apt install crowdsec-firewall-bouncer -y
    systemctl enable crowdsec-firewall-bouncer
    systemctl start crowdsec-firewall-bouncer
    log_info "Firewall bouncer 安装完成"
fi

# ============================================================
# 配置日志轮转
# ============================================================
log_section "配置日志轮转"

cat > /etc/logrotate.d/traefik-coolify << 'EOF'
/data/coolify/proxy/accesslogs/access.log {
    size 10M
    rotate 5
    missingok
    notifempty
    compress
    postrotate
        docker kill --signal="USR1" coolify-proxy 2>/dev/null || true
    endscript
}
EOF
log_info "日志轮转配置完成"

# ============================================================
# 最终验证
# ============================================================
log_section "最终验证"

systemctl restart crowdsec
sleep 3

log_info "服务状态："
systemctl is-active crowdsec \
    && log_info "  crowdsec:         运行中" \
    || log_error "  crowdsec:         未运行"
systemctl is-active crowdsec-firewall-bouncer \
    && log_info "  firewall-bouncer: 运行中" \
    || log_error "  firewall-bouncer: 未运行"

echo ""
log_info "日志采集状态（等待 5 秒采样）："
sleep 5
cscli metrics 2>/dev/null | grep -A 15 "Acquisition" || log_warn "暂无采集数据，等待流量进入后再检查"

echo ""
log_info "当前告警："
cscli alerts list 2>/dev/null || true

# ============================================================
# 完成
# ============================================================
log_section "安装完成"

echo ""
log_info "常用命令："
echo "  查看封锁列表:  cscli decisions list"
echo "  查看告警:      cscli alerts list"
echo "  手动封锁 IP:   cscli decisions add --ip 1.2.3.4"
echo "  手动解封 IP:   cscli decisions delete --ip 1.2.3.4"
echo "  查看采集指标:  cscli metrics"
echo "  实时日志:      tail -f /var/log/crowdsec.log"
echo ""
log_info "安装完成！建议用手机 4G 网络测试封锁效果，不要用当前 IP 测试。"
