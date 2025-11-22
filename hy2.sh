#!/usr/bin/env bash
# =====================================================
# Hysteria2 极简一键部署脚本（2025最新优化版）
# 特性：自动适配架构 │ 自动测速 │ 自签/自定义证书 │ Brutal 拥塞控制 │ 更稳定的 QUIC 参数
# 适用于 64MB~1GB 内存的海外 VPS
# =====================================================

set -euo pipefail
IFS=$'\n\t'

# ==================== 可自定义参数 ====================
HYSTERIA_VERSION="v2.6.5"                  # 如需更新只需改这里
DEFAULT_PORT=443                           # 默认端口，建议直接用 443
AUTH_PASSWORD="${RANDOM_PASSWORD:-$(openssl rand -base64 | md5sum | head -c 16)}"
# 密码优先级：环境变量 > 随机生成 > 手动改下面这行
# AUTH_PASSWORD="your-strong-password-here"

# 伪装域名（推荐用 Cloudflare CDN 节点）
SNI="pages.cloudflare.com"
ALPN="prime256v1"                           # 椭圆曲线，更快更省内存
ALPN="h3"
# =====================================================

# 颜色输出
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 获取命令行端口
if [[ $# -ge 1 ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
    SERVER_PORT="$1"
    info "使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="$DEFAULT_PORT"
    info "未指定端口，使用默认端口: $SERVER_PORT"
fi

# 架构检测
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)      echo "amd64" ;;
        aarch64|arm64)     echo "arm64" ;;
        armv7l|armv7)      echo "arm" ;;
        *) error "不支持的架构: $(uname -m)" ; exit 1 ;;
    esac
}
ARCH=$(detect_arch)
BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="/usr/local/bin/hysteria2"

# 下载最新版二进制（带缓存）
download_hysteria() {
    if [[ -x "$BIN_PATH" ]] && "$BIN_PATH" version 2>/dev/null | grep -q "$HYSTERIA_VERSION"; then
        info "Hysteria2 二进制已存在且版本正确，跳过下载"
        return
    fi

    local url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    info "正在下载 Hysteria2 ${HYSTERIA_VERSION} (${ARCH}) …"
    curl -L --fail --retry 5 --retry-delay 3 -o "$BIN_PATH" "$url" || {
        info "下载完成"
    } || {
        error "下载失败，请检查网络或 GitHub 是否被墙"
        exit 1
    }
    chmod +x "$BIN_PATH"
}

# 证书处理（优先使用已有证书 → acme.sh → 自签）
ensure_tls() {
    if [[ -f "fullchain.pem" && -f "privkey.pem" ]]; then
        CERT_FILE="fullchain.pem"
        KEY_FILE="privkey.pem"
        info "检测到 fullchain.pem / privkey.pem，已启用真实证书"
        return
    fi

    if command -v acme.sh >/dev/null 2>&1 && [[ -f "/root/.acme.sh/${SNI}_ecc/fullchain.cer" ]]; then
        CERT_FILE="/root/.acme.sh/${SNI}_ecc/fullchain.cer"
        KEY_FILE="/root/.acme.sh/${SNI}_ecc/${SNI}.key"
        info "检测到 acme.sh 证书，自动使用"
        return
    fi

    CERT_FILE="cert.pem"
    KEY_FILE="key.pem"
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        info "生成自签名 ECC 证书（${PN}，10年有效期）"
        openssl ecparam -genkey -name "$PN" -out "$KEY_FILE"
        openssl req -new -x509 -key "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
            -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}"
    fi
    info "使用自签名证书"
}

# 自动测速（多 CDN 兜底）
auto_speedtest() {
    info "自动测速中（最长15秒）..."
    local sources=(
        "https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn"
        "https://fastly.jsdelivr.net/gh/sjlleo/Trace/flushcdn"
        "https://gcore.jsdelivr.net/gh/sjlleo/Trace/flushcdn"
    )
    for src
    for src in "${sources[@]}"; do
        local result
        result=$(curl -s --max-time 12 "$src" ) && [[ "$result" != "" ]] || continue

        UP=$(echo "$result" | grep -o '[0-9]\+ Mbps' | sed -n 1p | awk '{print $1}')
        DOWN=$(echo "$result" | grep -o '[0-9]\+ Mbps' | sed -n 2p | awk '{print $1}')
        [[ -n "$UP" && -n "$DOWN" ]] && break
    done

    # 兜底值
    UP=${UP:-200}
    DOWN=${DOWN:-300}

    # 给 Brutal 留足空间，实际填高一点
    UP_MBIT=$(( UP * 6 / 5 ))
    DOWN_MBIT=$(( DOWN * 6 / 5 ))

    info "测速结果 → 上行 ${UP}Mbps → 填 ${UP_MBIT}Mbps   下行 ${DOWN}Mbps → 填 ${DOWN_MBIT}Mbps"
}

# 写配置文件
write_config() {
    cat > /etc/hysteria2.yaml <<EOF
listen: :${SERVER_PORT}

tls:
  cert: $(realpath "$CERT_FILE")
  key: $(realpath "$KEY_FILE")

auth:
  type: password
  password: ${AUTH_PASSWORD}

bandwidth:
  up: ${UP_MBIT} mbps
  down: ${DOWN_MBIT} mbps

brutal:
  enabled: true
  sendBBR: false

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF
    info "配置文件已写入 /etc/hysteria2.yaml"
}

# 获取公网 IP
get_ip() {
    curl -s --max-time 8 https://api.ipify.org || curl -s https://ifconfig.me
}

# 打印信息 & 生成客户端链接
print_info() {
    local ip=$(get_ip)
    echo
    echo "════════════════════════════════════════════════"
    echo "           Hysteria2 部署完成！"
    echo "════════════════════════════════════════════════"
    echo "服务器 IP   : $ip"
    echo "端口        : $SERVER_PORT"
    echo "密码        : $AUTH_PASSWORD"
    echo "带宽填充    : 上行 ${UP_MBIT}Mbps / 下行 ${DOWN_MBIT}Mbps"
    echo "SNI         : $SNI"
    echo "跳过证书验证: 是（insecure=1）"
    echo
    echo "【客户端一键导入链接】"
    echo "hysteria2://${AUTH_PASSWORD}@${ip}:${SERVER_PORT}/?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Brutal-${ip}"
    echo
    echo "建议配合 Clash Meta / Nekobox / Sing-Box 使用"
    echo "════════════════════════════════════════════════"
}

# ==================== 主流程 ====================
main() {
    [[ $EUID -ne 0 ]] && error "请用 root 权限运行" && exit 1

    download_hysteria
    ensure_tls
    auto_speedtest
    write_config

    # 启动方式一：直接前台运行（适合 screen/tmux）
    print_info
    echo "正在启动 Hysteria2 服务端..."
    exec "$BIN_PATH" server -c /etc/hysteria2.yaml
}

main "$@"
