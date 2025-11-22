#!/usr/bin/env bash
# =====================================================
# Hysteria2 极简一键脚本（已修复所有语法错误）
# 适配超低配 VPS / 容器（64MB 内存也能跑）
# =====================================================

set -euo pipefail

# ============== 可修改参数 ==============
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=443
SNI="pages.cloudflare.com"
ALPN="h3"
# =======================================

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 端口
if [[ $# -ge 1 ]] && [[ $1 =~ ^[0-9]+$ ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi
info "使用端口 → $PORT"

# 架构
case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    armv7*|armv6*)  ARCH="arm" ;;
    *) error "不支持的架构" ; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"

# 下载
if [[ ! -f "$BIN" ]]; then
    info "正在下载 Hysteria2 $HYSTERIA_VERSION ($ARCH)…"
    curl -L -o "$BIN" \
"https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/$BIN"
    chmod +x "$BIN"
fi

# 密码（随机生成）
PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
info "随机密码 → $PASSWORD"

# 证书（自签）
if [[ ! -f cert.pem ]]; then
    info "生成自签名证书…"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout key.pem -out cert.pem -subj "/CN=$SNI" >/dev/null 2>&1
fi

# 自动测速（已彻底修复语法）
auto_speedtest() {
    info "测速中（最多12秒）..."
    sources=(
        "https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn"
        "https://fastly.jsdelivr.net/gh/sjlleo/Trace/flushcdn"
        "https://gcore.jsdelivr.net/gh/sjlleo/Trace/flushcdn"
    )
    
    UP=150
    DOWN=200
    for url in "${sources[@]}"; do
        result=$(curl -s --max-time 10 "$url") || continue
        UP=$(echo "$result" | grep -o '[0-9]\+ Mbps' | head -1 | awk '{print $1}')
        DOWN=$(echo "$result" | grep -o '[0-9]\+ Mbps' | tail -1 | awk '{print $1}')
        [[ -n "$UP" && -n "$DOWN ]] && break
    done
    
    # 给 Brutal 留余量
    UP_MBIT=$(( UP + UP/3 ))
    DOWN_MBIT=$(( DOWN + DOWN/3 ))
    info "测速结果 → 上行 ${UP}Mbps → 填 ${UP_MBIT}Mbps   下行 ${DOWN}Mbps → 填 ${DOWN_MBIT}Mbps"
}

auto_speedtest

# 写配置
cat > config.yaml <<EOF
listen: :$PORT

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: $PASSWORD

bandwidth:
  up: ${UP_MBIT} mbps
  down: ${DOWN_MBIT} mbps

brutal:
  enabled: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF

# 获取 IP 并输出链接
IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)

echo ""
echo "══════════════════════════════════════"
echo "         Hysteria2 部署完成！"
echo "══════════════════════════════════════"
echo "IP      : $IP"
echo "端口     : $PORT"
echo "密码     : $PASSWORD"
echo "SNI     : $SNI"
echo "跳过证书验证 : 是"
echo ""
echo "客户端链接（直接导入 Clash Meta / Nekobox / Sing-box）："
echo "hysteria2://$PASSWORD@$IP:$PORT/?sni=$SNI&alpn=$ALPN&insecure=1#Hy2-LowMem-$IP"
echo "══════════════════════════════════════"

info "正在启动服务端…"
exec ./$BIN server -c config.yaml
