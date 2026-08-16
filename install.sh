#!/usr/bin/env bash
# ============================================================
# 透明代理网关一键安装脚本
#   sudo bash install.sh
# 前置: 复制 config.env.example 为 config.env 并填写实际值
#   cp config.env.example config.env && vim config.env
# 幂等, 可重复执行; 重复执行会刷新订阅并重启服务
# ============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_CONF="/etc/gateway"
CONFIG_ENV="$GATEWAY_CONF/config.env"

log()  { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m==!>\033[0m $*"; }

# ---------- 前置检查 ----------
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行: sudo bash install.sh"; exit 1; }

if [ -f "$REPO_DIR/config.env" ]; then
    mkdir -p "$GATEWAY_CONF"
    cp "$REPO_DIR/config.env" "$CONFIG_ENV"
    chmod 600 "$CONFIG_ENV"
    log "已复制仓库目录 config.env -> $CONFIG_ENV"
elif [ -f "$CONFIG_ENV" ]; then
    log "使用已有配置 $CONFIG_ENV"
else
    echo "未找到配置。请先将 config.env.example 复制为 config.env 并填写:"
    echo "  cp config.env.example config.env"
    echo "  vim config.env"
    echo "然后重新运行: sudo bash install.sh"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_ENV"
set +a

if [[ "${SUB_URL:-}" == *example.com* || -z "${SUB_URL:-}" ]]; then
    echo "错误: SUB_URL 未填写 (见 $CONFIG_ENV)"; exit 1
fi

# ---------- 系统依赖 ----------
log "安装系统依赖 (nftables/python3-yaml/curl/unzip/dnsutils)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nftables python3-yaml curl unzip dnsutils

# ---------- 架构检测 ----------
case "$(uname -m)" in
    aarch64)  ARCH=arm64 ;;
    armv7l)   ARCH=armv7 ;;
    x86_64)   ARCH=amd64 ;;
    i386|i686) ARCH=386 ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac
log "架构: $ARCH"

GH_BASE="${GH_PROXY:-https://github.com}"
MIHOMO_VERSION="${MIHOMO_VERSION:-1.19.30}"
MOSDNS_VERSION="${MOSDNS_VERSION:-5.3.4}"

# ---------- 下载二进制 ----------
mkdir -p /usr/local/bin /etc/mihomo/ruleset /etc/mosdns "$GATEWAY_CONF"

download() { # url dest
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

if [ ! -x /usr/local/bin/mihomo ]; then
    log "下载 mihomo v${MIHOMO_VERSION}"
    URL="${GH_BASE}/github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-${ARCH}-v${MIHOMO_VERSION}.gz"
    download "$URL" /tmp/mihomo.gz
    gzip -dc /tmp/mihomo.gz > /usr/local/bin/mihomo
    chmod +x /usr/local/bin/mihomo
    rm -f /tmp/mihomo.gz
fi

if [ ! -x /usr/local/bin/mosdns ]; then
    log "下载 mosdns v${MOSDNS_VERSION}"
    URL="${GH_BASE}/github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/mosdns-linux-${ARCH}.zip"
    download "$URL" /tmp/mosdns.zip
    cd /tmp && unzip -q -o mosdns.zip -d mosdns-extract
    mv -f /tmp/mosdns-extract/mosdns /usr/local/bin/mosdns
    chmod +x /usr/local/bin/mosdns
    rm -rf /tmp/mosdns.zip /tmp/mosdns-extract
fi

/usr/local/bin/mihomo -v && /usr/local/bin/mosdns version

# ---------- 部署配置 ----------
log "部署系统配置"
cp -f "$REPO_DIR/sysctl/99-gateway.conf" /etc/sysctl.d/99-gateway.conf
/sbin/sysctl --system >/dev/null

cp -f "$REPO_DIR/mosdns/config.yaml" /etc/mosdns/config.yaml
cp -f "$REPO_DIR/convert.py" "$GATEWAY_CONF/convert.py"
chmod 700 "$GATEWAY_CONF"

# systemd 单元
for u in mosdns mihomo gateway-forward; do
    cp -f "$REPO_DIR/systemd/$u.service" "/etc/systemd/system/$u.service"
done
cp -f "$REPO_DIR/systemd/mihomo-refresh.service" /etc/systemd/system/mihomo-refresh.service
cp -f "$REPO_DIR/systemd/mihomo-refresh.timer" /etc/systemd/system/mihomo-refresh.timer
systemctl daemon-reload

# Tailscale 路由 + LAN NAT drop-in (按配置生成)
# 注意: --netfilter-mode=off 时 tailscaled 不安装子网 NAT 规则,
# 需手动 MASQUERADE, 否则 LAN->Tailnet 流量不 SNAT 而超时
if [ -n "${TAILNET_ROUTE:-}" ] || [ -n "${LAN_SUBNET:-}" ]; then
    mkdir -p /etc/systemd/system/tailscaled.service.d
    {
        echo "[Service]"
        [ -n "${TAILNET_ROUTE:-}" ] && \
            echo "ExecStartPost=+/usr/sbin/ip route replace ${TAILNET_ROUTE} dev tailscale0"
        [ -n "${LAN_SUBNET:-}" ] && \
            echo "ExecStartPost=+/usr/sbin/iptables -t nat -A POSTROUTING -s ${LAN_SUBNET} -o tailscale0 -j MASQUERADE"
    } > /etc/systemd/system/tailscaled.service.d/route.conf
    systemctl daemon-reload
fi

# docker FORWARD 兜底 drop-in (无论 docker 是否已装都写入, 防止后续安装时被重置)
mkdir -p /etc/systemd/system/docker.service.d
cp -f "$REPO_DIR/dropins/docker-forward-accept.conf" \
    /etc/systemd/system/docker.service.d/forward-accept.conf
systemctl daemon-reload

# ---------- 生成 Mihomo 配置 + 分流数据 ----------
log "运行配置转换器 (订阅/cira/geosite)"
python3 "$GATEWAY_CONF/convert.py"
/usr/local/bin/mihomo -d /etc/mihomo -t || { echo "mihomo 配置校验失败"; exit 1; }

# ---------- MosDNS ----------
log "启动 mosdns"
systemctl enable --now mosdns
sleep 1
systemctl is-active mosdns >/dev/null

# ---------- Tailscale (可选) ----------
if [[ -n "${TAILSCALE_AUTHKEY:-}" && "${TAILSCALE_AUTHKEY}" != hskey-auth-REPLACE* ]]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        log "安装 tailscale"
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    systemctl enable tailscaled
    log "接入 Tailnet: ${TAILSCALE_LOGIN_SERVER}"
    # --netfilter-mode=off: tailscaled 自带反欺骗规则会丢弃经 lo 回环到达的
    # 对端应答 (本机 tailscale IP 在本地路由表走 lo), 导致 Tailnet 连接失败
    # --advertise-routes: 广播 LAN 子网, 否则 tailscaled 拒绝该子网来源的
    # 拨号 (mihomo DIRECT 拨号源为网关 IP), LAN 侧无法访问 Tailnet
    ARGS=(--login-server="$TAILSCALE_LOGIN_SERVER" --authkey="$TAILSCALE_AUTHKEY" --netfilter-mode=off)
    [ "${TAILSCALE_ACCEPT_ROUTES:-yes}" = yes ] && ARGS+=(--accept-routes)
    [ -n "${LAN_SUBNET:-}" ] && ARGS+=(--advertise-routes="$LAN_SUBNET")
    tailscale up "${ARGS[@]}" || warn "tailscale up 失败, 请手动检查"
else
    warn "未配置 TAILSCALE_AUTHKEY, 跳过 Tailscale"
fi

# ---------- 转发策略 ----------
log "设置 FORWARD 策略并启用服务"
iptables -P FORWARD ACCEPT
ip6tables -P FORWARD ACCEPT
systemctl enable --now gateway-forward

# ---------- Mihomo ----------
log "启动 mihomo"
systemctl enable --now mihomo
sleep 5
systemctl is-active mihomo >/dev/null

# ---------- 定时刷新 ----------
log "启用每周订阅刷新定时器"
systemctl enable --now mihomo-refresh.timer

# ---------- WebUI ----------
log "检查 WebUI"
mkdir -p /etc/mihomo/ui
if [ -n "$(ls -A /etc/mihomo/ui 2>/dev/null)" ] && grep -q "external-ui" /etc/mihomo/config.yaml; then
    log "config.yaml 已配置 external-ui 且 UI 文件存在, 跳过下载"
else
    log "下载 WebUI (metacubexd)"
    download "${GH_BASE}/github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip" /tmp/mcxd.zip
    cd /tmp && unzip -q -o mcxd.zip -d mcxd-extract
    cp -r /tmp/mcxd-extract/metacubexd-gh-pages/* /etc/mihomo/ui/
    rm -rf /tmp/mcxd.zip /tmp/mcxd-extract
    systemctl restart mihomo
fi

# ---------- 汇总 ----------
SECRET="$(cat /etc/mihomo/secret 2>/dev/null || true)"
echo
echo "==================== 安装完成 ===================="
echo "  mihomo WebUI: http://$(hostname -I | awk '{print $1}'):9090/ui/"
echo "  WebUI 密钥:   ${SECRET:-重启 mihomo 后生成}"
echo "  mosdns DNS:   $(hostname -I | awk '{print $1}'):53"
echo "  默认出口:     ${NODE_DEFAULT}"
echo "  VoWiFi:       ${NODE_VOWIFI} (经 ${NODE_VOWIFI_FRONT} 前置)"
echo "=================================================="
echo "LAN 客户端: 网关与 DNS 均指向本机 IP, 即可透明代理。"
echo "注意: 若同时运行 Docker, 其 FORWARD 策略已由 docker drop-in 兜底。"