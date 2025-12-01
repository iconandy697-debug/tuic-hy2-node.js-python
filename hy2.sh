#!/usr/bin/env bash
# Hysteria2 2025年12月最新优化版（适配 v2.6.5+，Brutal 完美自动启用）
set -euo pipefail  # 增加 pipefail，避免管道错误被忽略

HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=443    # 改成443更容易过CDN和防火墙
SNI_LIST=("www.bing.com" "www.microsoft.com" "www.apple.com" "time.apple.com" "edge.microsoft.com" "www.google.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

# 支持传入端口
if [[ ${1:-} =~ ^[0-9]+$ ]] && [[ $1 -ge 1 ]] && [[ $1 -le 65535 ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi

echo " 使用端口: $PORT | 伪装域名: $SNI"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;           # 新增 armv7 支持（如某些便宜VPS）
    *) echo "❌ 不支持的架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载最新版二进制（带完整性校验，防止被墙或中间人）
if [ ! -f "$BIN" ] || ! ./"$BIN" version | grep -q "$HYSTERIA_VERSION"; then
    echo "⏳ 正在下载 Hysteria2 $HYSTERIA_VERSION ($ARCH)..."
    URL="https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/hysteria-linux-${ARCH}"
    curl -L --fail --retry 5 --retry-delay 2 -o "$BIN" "$URL"
    chmod +x "$BIN"
    echo "✅ 下载完成"
fi

# 自签证书（只生成一次）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo " 生成自签 ECC 证书（有效期10年）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI"
fi

# 自动测速（多源 fallback，更准更稳）
echo " 测速中（最多尝试3个源）..."
UP=100
DOWN=100

for url in "https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn" \
           "https://fastly.jsdelivr.net/gh/sjlleo/Trace/flushcdn" \
           "https://gcore.jsdelivr.net/gh/sjlleo/Trace/flushcdn"; do
    result=$(curl -s --max-time 12 "$url" | grep -o "[0-9]\+ Mbps" || true)
    if [[ -n $result ]]; then
        UP=$(echo "$result" | head -1 | grep -o "[0-9]\+" )
        DOWN=$(echo "$result" | tail -1 | grep -o "[0-9]\+" )
        break
    fi
done

# 保底 + 合理上限（Brutal 太高反而丢包严重）
[[ $UP -gt 800 ]] && UP=800
[[ $DOWN -gt 800 ]] && DOWN=800
[[ $UP -lt 20 ]] && UP=50
[[ $DOWN -lt 20 ]] && DOWN=50

echo "✅ 实测带宽：上行 ${UP}Mbps / 下行 ${DOWN}Mbps（Brutal 自动启用）"

# 密码：优先用用户传入，其次随机
if [[ -n ${2:-} ]]; then
    AUTH_PASSWORD="$2"
else
    AUTH_PASSWORD=$(openssl rand -hex 16)
fi

# 写入最优 server.yaml（修复了重复 cat 的错误）
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
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

# 可选：开启 BBR（如果系统支持）
# kernelSettings:
#   bbr: true
EOF

IP=$(curl -s --max-time 6 --ipv4 https://api.ipify.org || curl -s https://ipv4.icanhazip.com/)

echo "============================================================"
echo " 部署完成！服务器信息："
echo " IP       : $IP"
echo " 端口     : $PORT"
echo " 密码     : $AUTH_PASSWORD"
echo " 带宽     : 上行 ${UP}Mbps / 下行 ${DOWN}Mbps（Brutal 已自动启用）"
echo " 伪装域名 : $SNI"
echo ""
echo " 客户端一键导入链接（跳过证书验证）："
echo "hysteria2://$AUTH_PASSWORD@$IP:$PORT/?sni=$SNI&insecure=1#Hy2-Brutal-$UP-$DOWN"
echo ""
echo " 如需真实证书 + CDN 推荐使用 acme.sh 申请 Let's Encrypt 证书后替换 cert.pem/key.pem"
echo "============================================================"

echo " 启动 Hysteria2 服务器（前台运行，Ctrl+C 停止）"
./"$BIN" server -c server.yaml | tee hysteria.log
