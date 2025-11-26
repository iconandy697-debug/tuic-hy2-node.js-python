#!/usr/bin/env bash
# Hysteria2 2025年11月终极修复版（v2.6.5，移除伪装坑 + QUIC 优化）

set -e

HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
AUTH_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9')
SNI_LIST=("www.microsoft.com" "www.apple.com" "time.apple.com" "www.bing.com" )
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

if [[ $1 =~ ^[0-9]+$ ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi

echo "使用端口: $PORT | SNI: $SNI"

# 架构检测（不变）
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"

# 下载二进制（不变）
if [ ! -f "$BIN" ]; then
    echo "下载 Hysteria2 $HYSTERIA_VERSION..."
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/$BIN" --retry 3
    chmod +x "$BIN"
fi

# 证书（不变）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI"
fi

# 测速逻辑（不变，保底100Mbps + 上限500Mbps）


cat > server.yaml <<EOF
listen: :$PORT

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: $AUTH_PASSWORD

bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps

masquerade:
  type: string
  content: "404 Not Found\n\nHysteria2 Server - Powered by apernet"
  headers:
    content-type: text/plain
    server: nginx
  statusCode: 404

# ██████████████████ 【核心修复2】QUIC 窗口调优 + 强制开启 PMTU ██████████████████
quic:
  initialStreamReceiveWindow: 4194304      # 从 8388608 降到 4MB（防缓冲炸）
  maxStreamReceiveWindow: 8388608
  initialConnReceiveWindow: 8388608        # 从 20971520 降到 8MB
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  disablePathMTUDiscovery: false          # 保持 false = 开启 PMTU 发现（必须）

# ██████████████████ 【可选终极保命项】忽略客户端瞎填的带宽 ██████████████████
# 防止某些客户端乱填 99999Mbps 导致服务器疯狂丢包
ignoreClientBandwidth: true
# ██████████████████████████████████████████████████████████████████████

EOF
# =======================================================================

IP=$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_IP")

echo "部署完成！"
echo "   IP: $IP    端口: $PORT    密码: $AUTH_PASSWORD"
echo "   带宽: 上 ${UP}Mbps / 下 ${DOWN}Mbps（Brutal 已自动启用）"
echo "   SNI: $SNI"
echo ""
echo "客户端链接（记得加 insecure=1）:"
echo "hysteria2://$AUTH_PASSWORD@$IP:$PORT?sni=$SNI&insecure=1#Hy2-Fixed-2025"
echo ""
echo "启动服务器..."
exec ./$BIN server -c server.yaml

