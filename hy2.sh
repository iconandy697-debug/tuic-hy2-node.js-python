#!/usr/bin/env bash
# Hysteria2 2025 纯 TLS 终极稳定版（64MB WispByte 专用）
# 零配置错误 · 零 obfs · 伪装最强 · 速度最快

set -e

# 随机强密码
gen_pw() { openssl rand -base64 32 | head -c20; }
PASS=$(gen_pw)
PORT=${1:-443}                                 # 支持传入端口
SNI="www.google.com"                           # 可换 cloudflare.com / bing.com

# 架构
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

BIN="hysteria-linux-${ARCH}"

# 下载二进制
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $URL"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
}
# 获取 IP（用于证书 SAN）
IP=$(curl -s4 ifconfig.co || curl -s4 ipinfo.io/ip || echo "127.0.0.1")

# 生成自签证书（带 IP 和 DNS 的 SAN）
[ -f cert.pem ] || [ -f key.pem ] || {
  echo "生成自签证书（10年有效）..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -subj "/CN=${SNI}" \
    -addext "subjectAltName=DNS:${SNI},IP:${IP}"
}

# 写入最终完美配置
cat > config.yaml <<EOF
listen: :${PORT}

tls:
  cert: $(pwd)/cert.pem
  key:  $(pwd)/key.pem

auth:
  type: password
  password: ${PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/favicon.ico
    rewriteHost: true

# 64MB 小鸡最优带宽（再高反而掉速）
bandwidth:
  up: 50 mbps
  down: 100 mbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

fastOpen: true
lazy: true
EOF

echo "===================================================="
echo "        Hysteria2 已准备就绪（纯 TLS 版）"
echo "===================================================="
echo "IP地址 : $IP"
echo "端口     : $PORT"
echo "密码     : $PASS"
echo "SNI      : $SNI"
echo ""
echo "客户端链接（直接导入）："
echo "hysteria2://${PASS}@${IP}:${PORT}/?sni=${SNI}&alpn=h3&insecure=1#Hy2-Google"
echo ""
echo "启动中..."
exec ./"$BIN" server -c config.yaml
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
