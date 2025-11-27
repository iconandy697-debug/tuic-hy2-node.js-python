#!/usr/bin/env bash
# Hysteria2 2025 纯 TLS 终极版（WispByte 64MB 专属，零配置错误）
# 无 acme/obfs，纯 masquerade + 自签 TLS，必成 + 高速

set -e

# 随机强密码（20 位 base64）
gen_pw() { openssl rand -base64 32 | head -c 20; }
PASS=$(gen_pw)
PORT=${1:-443}  # 支持命令行端口，如 bash script.sh 8443
SNI="www.google.com"  # 伪装目标，可换 www.cloudflare.com

# 架构检测（支持 amd64/arm64）
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "❌ 不支持架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载 v2.6.5（稳定版，重试机制）
if [ ! -f "$BIN" ]; then
  echo "⏳ 下载 Hysteria2 v2.6.5 ($ARCH) ..."
  if ! curl -L --retry 3 --connect-timeout 10 -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}"; then
    wget -O "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}"
  fi
  chmod +x "$BIN"
  echo "✅ 下载完成。"
fi

# 获取服务器 IP（用于证书 SAN）
SERVER_IP=$(curl -s4 ifconfig.co || curl -s4 ipinfo.io/ip || echo "127.0.0.1")

# 生成自签证书（P-384 曲线 + SAN 扩展，包含 IP/SNI）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  echo "🔑 生成自签证书 (SNI: $SNI, IP: $SERVER_IP)..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -subj "/CN=${SNI}" \
    -addext "subjectAltName=DNS:${SNI},IP:${SERVER_IP}"
  echo "✅ 证书生成成功（10 年有效）。"
fi

# 写入纯净配置（只 tls，无 acme/obfs）
cat > config.yaml <<EOF
listen: :${PORT}

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: ${PASS}

# 伪装流量（像正常访问 Google 图标，抗检测最强）
masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/favicon.ico
    rewriteHost: true

# 带宽调优（低配机满速，忽略客户端报告以防误配）
bandwidth:
  up: 20 mbps
  down: 50 mbps
  ignoreClientBandwidth: true

# QUIC 优化（大窗口 + lazy 模式，内存友好）
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

# 获取公网 IP（备用）
PUB_IP=$(curl -s4 ifconfig.co || curl -s4 ipinfo.io/ip || echo "YOUR_IP")

echo "===================================================="
echo "    🎉 Hysteria2 部署成功！（纯 TLS 零冲突版）"
echo "===================================================="
echo "🌐 服务器 IP: $PUB_IP"
echo "🔌 端口: $PORT"
echo "🔑 密码: $PASS"
echo "🛡️ SNI (伪装): $SNI"
echo ""
echo "📱 客户端导入链接（Nekobox/Clash/Singbox 直接粘贴）："
echo "hysteria2://${PASS}@${PUB_IP}:${PORT}/?sni=${SNI}&alpn=h3&insecure=1#Hy2-TLS-2025"
echo ""
echo "⚠️ 客户端必须加 &insecure=1（跳过自签证书验证）。伪装已内置，无需 obfs。"
echo "💡 测试命令（服务器端）：nc -l ${PORT} （或用 ss-local 测试连接）"
echo "===================================================="
echo "🚀 启动服务器...（预期日志: INFO listening on :${PORT}）"
exec ./"$BIN" server -c config.yaml
