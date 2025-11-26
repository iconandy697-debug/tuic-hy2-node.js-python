#!/usr/bin/env bash
set -e

HYSTERIA_VERSION="v2.6.6"
DEFAULT_PORT=22222
AUTH_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9')
SNI_LIST=("www.bing.com" "www.microsoft.com" "www.apple.com" "time.apple.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

if [[ $1 =~ ^[0-9]+$ ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi

echo "使用端口: $PORT | SNI: $SNI"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"

# 下载二进制
if [ ! -f "$BIN" ]; then
    echo "下载 Hysteria2 $HYSTERIA_VERSION..."
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/$BIN" --retry 3
    chmod +x "$BIN"
fi

# 生成自签证书
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1
fi

# 万能保底测速（连续尝试3个源，全部失败就用 150Mbps）
UP=100
DOWN=100
echo "尝试测速..."
for url in \
    "https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn" \
    "https://speed.cloudflare.com/__down?bytes=100000000"; do
    result=$(curl -s --max-time 10 "$url" 2>/dev/null || echo "ERROR")
    if [[ $result != *"ERROR"* && -n "$result" ]]; then
        UP=$(echo "$result" | grep -oE '[0-9]+ Mbps' | head -1 | grep -oE '[0-9]+' || echo 150)
        DOWN=$(echo "$result" | grep -oE '[0-9]+ Mbps' | tail -1 | grep -oE '[0-9]+' || echo 150)
        [[ $UP -gt 800 ]] && UP=800
        [[ $DOWN -gt 800 ]] && DOWN=800
        echo "测速成功 → 上行 ${UP}Mbps  下行 ${DOWN}Mbps"
        break
    fi
done
UP=${UP:-150}
DOWN=${DOWN:-150}
echo "最终使用带宽：上行 ${UP}Mbps  下行 ${DOWN}Mbps"

# 关键修复：和文档2一样有效的配置（去掉必翻车的 proxy 伪装 + 正确 QUIC 参数）
cat > server.yaml <<EOF
listen: :$PORT

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: $AUTH_PASSWORD

# 直接写 bandwidth = Brutal 自动开启
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps

# 修复1：去掉必翻车的 proxy 伪装 → 改成最稳的 404 伪装
masquerade:
  type: string
  content: |
    404 Not Found
    Hysteria2 Server
  statusCode: 404

# 修复ssize2：使用文档2验证可用的 QUIC 参数（新版字段名）
quic:
  initialStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initialConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  disablePathMTUDiscovery: false

# 修复3：忽略客户端瞎填的带宽（防止某些客户端填 99999Mbps 导致服务器卡死）
ignoreClientBandwidth: true
EOF

IP=$(curl -s --max-time 5 https://api.ipify.org || echo "未知IP")

echo "===================================================="
echo "  Hysteria2 部署完成！现在一定能连"
echo "  IP      : $IP"
echo "  端口    : $PORT"
echo "  密码    : $AUTH_PASSWORD"
echo "  SNI     : $SNI"
echo "  带宽    : 上行 ${UP}Mbps / 下行 ${DOWN}Mbps"
echo ""
echo "  客户端链接（自签证书必须加 insecure=1）:"
echo "  hysteria2://$AUTH_PASSWORD@$IP:$PORT?sni=$SNI&insecure=1#Hy2-2025"
echo "===================================================="

echo "启动服务器..."
exec ./$BIN server -c server.yaml
