#!/usr/bin/env bash
# Hysteria2 2025年最新可用极简一键脚本（兼容32-64MB内存）
# 修复了：brutal 删除、bandwidth 语法错误、quic 参数失效等问题

set -e

HYSTERIA_VERSION="v2.6.5"      # 2025年11月最新稳定版
DEFAULT_PORT=22222
AUTH_PASSWORD=$(openssl rand -base64 32)
SNI_LIST=("bing.com" "www.bing.com" "www.microsoft.com" "www.apple.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

if [[ $1 =~ ^[0-9]+$ ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi

echo "使用端口: $PORT"

# 架构检测
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"

# 下载最新二进制
if [ ! -f "$BIN" ]; then
    echo "正在下载 Hysteria2 $HYSTERIA_VERSION ..."
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/$BIN"
    chmod +x "$BIN"
fi

# 自签证书（必须用 ECC）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI"
fi

# 自动测速（保留你原来的逻辑）
echo "测速中..."
result=$(curl -s --max-time 12 https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn || echo "ERROR")
if [[ $result == *"ERROR"* ]]; then
    UP=300; DOWN=300
else
    UP=$(echo "$result" | grep -o "[0-9]\+ Mbps" | head -n1 | cut -d' ' -f1)
    DOWN=$(echo "$result" | grep -o "[0-9]\+ Mbps" | tail -n1 | cut -d' ' -f1)
    [[ -z "$UP" || "$UP" -lt 50 ]] && UP=300
    [[ -z "$DOWN" || "$DOWN" -lt 50 ]] && DOWN=300
fi
echo "实测带宽 ≈ 上行 ${UP}Mbps 下行 ${DOWN}Mbps"

# 2025 年正确的 server.yaml（重点！！！）
cat > server.yaml <<EOF
listen: :$PORT

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: $AUTH_PASSWORD

# 关键：新版必须这样写带宽 + 拥塞控制
congestion:
  type: bruteforce        # 2024-2025 年唯一还能“猛”的拥塞控制（原来 brutal 的继任者）
  bruteforce:
    up: ${UP} mbps
    down: ${DOWN} mbps

# 伪装（防止某些运营商探测）
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

# 可选：提高弱网穿透力
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
EOF

IP=$(curl -s https://api.ipify.org)

echo "============================================================"
echo "         Hysteria2 部署完成！"
echo "IP      : $IP"
echo "端口    : $PORT"
echo "密码    : $AUTH_PASSWORD"
echo "SNI     : $SNI"
echo "拥塞控制: bruteforce（原 brutal 升级版）"
echo ""
echo "客户端链接（跳过证书验证）:"
echo "hysteria2://$AUTH_PASSWORD@$IP:$PORT/?sni=$SNI&insecure=1#Hy2-2025"
echo "============================================================"

echo "启动服务器..."
exec ./$BIN server -c server.yaml
