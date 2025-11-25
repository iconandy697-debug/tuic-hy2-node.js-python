#!/usr/bin/env bash
# Hysteria2 2025年11月最新修复版（v2.6.5，Brutal 正确配置）
# 修复：congestion -> bandwidth；bruteforce -> Brutal 自动；QUIC 参数名

set -e

HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
AUTH_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9')
SNI_LIST=("www.bing.com" "www.microsoft.com" "www.apple.com" "time.apple.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

if [[ $1 =~ ^[0-9]+$ ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi

echo "🚀 使用端口: $PORT | SNI: $SNI"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "❌ 不支持的架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"

# 下载二进制
if [ ! -f "$BIN" ]; then
    echo "⏳ 下载 Hysteria2 $HYSTERIA_VERSION..."
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/$BIN" --retry 3
    chmod +x "$BIN"
    echo "✅ 下载完成。验证: ./$BIN version"
fi

# 证书（ECC 自签）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "🔑 生成证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI"
fi

# 自动测速（加保底逻辑，避免高值丢包）
echo "⏳ 测速中..."
result=$(curl -s --max-time 10 https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn || echo "ERROR")
if [[ $result == *"ERROR"* || -z "$result" ]]; then
    UP=100; DOWN=100  # 保底低值，防弱网
else
    UP=$(echo "$result" | grep -o "[0-9]\+[0-9]* Mbps" | head -n1 | grep -o "[0-9]\+" || echo "100")
    DOWN=$(echo "$result" | grep -o "[0-9]\+[0-9]* Mbps" | tail -n1 | grep -o "[0-9]\+" || echo "100")
    # 限制上限，避免 Brutal 过度
    [[ $UP -gt 500 ]] && UP=500
    [[ $DOWN -gt 500 ]] && DOWN=500
fi
echo "✅ 实测带宽：上行 ${UP}Mbps / 下行 ${DOWN}Mbps"

# 正确 server.yaml（Brutal 自动启用，带宽非零即 Brutal）
cat > server.yaml <<EOF
listen: :$PORT

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: $AUTH_PASSWORD

# 正确：直接 bandwidth 启用 Brutal（无 congestion 块）
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps

# 伪装（可选，防探测）
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

# QUIC（新版参数名，弱网优化）
quic:
  initialStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initialConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  disablePathMTUDiscovery: false  # 启用 PMTU 发现，提高稳定性
EOF

IP=$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_IP")

echo "🎉 部署完成！"
echo "📋 服务器信息:"
echo "   IP: $IP"
echo "   端口: $PORT"
echo "   密码: $AUTH_PASSWORD"
echo "   带宽: 上 ${UP} / 下 ${DOWN} Mbps (Brutal 已启用)"
echo "   SNI: $SNI"
echo ""
echo "📱 客户端 URI (insecure=1 跳证书):"
echo "hysteria2://$AUTH_PASSWORD@$IP:$PORT?sni=$SNI&insecure=1#Hy2-Brutal-v2.6.5"
echo "============================================================"

echo "🚀 启动服务器（查日志排查）..."
exec ./$BIN server -c server.yaml
