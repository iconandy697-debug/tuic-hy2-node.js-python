#!/usr/bin/env bash
# Hysteria2 2025终极 tls-only 版（WispByte 专属，零配置错误）
# 纯自签 tls + masquerade 伪装，无 acme 冲突，必成！

set -e

# 随机密码
gen_pw() { openssl rand -base64 32 | head -c20; }
PASS=$(gen_pw)
PORT=${1:-443}
SNI="www.google.com"  # 随机轮换：可换 www.microsoft.com / www.cloudflare.com

# 架构检测
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载 v2.6.5（稳定版）
if [ ! -f "$BIN" ]; then
  echo "下载 Hysteria2 v2.6.5 ($ARCH) ..."
  curl -L --retry 3 -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}" || \
  wget -O "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}"
  chmod +x "$BIN"
fi

# 生成高强度自签证书（fallback 无需 acme）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  echo "生成自签证书 (SNI: $SNI, P-384 曲线)..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -subj "/CN=${SNI}" \
    -addext "subjectAltName=DNS:${SNI},IP:$(curl -s4 ifconfig.co || echo 127.0.0.1)"
  echo "证书生成成功。"
fi

# 写入纯净配置（只用 tls，无 acme/obfs）
cat > config.yaml <<EOF
listen: :${PORT}

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: ${PASS}

# 伪装成正常 HTTPS（流量像访问 Google 图标）
masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/favicon.ico
    rewriteHost: true

# 带宽调优（低配满速）
bandwidth:
  up: 100 mbps
  down: 100 mbps

# QUIC 优化（内存友好）
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

fastOpen: true
lazy: true
ignoreClientBandwidth: true
EOF

# 获取 IP
IP=$(curl -s4 ifconfig.co || curl -s4 ipinfo.io/ip || echo "YOUR_IP")

echo "===================================================="
echo "    Hysteria2 部署成功！（tls-only 纯伪装版）"
echo "===================================================="
echo "IP: $IP"
echo "端口: $PORT"
echo "密码: $PASS"
echo "SNI: $SNI"
echo ""
echo "客户端链接（直接导入 Nekobox/Clash/Singbox）:"
echo "hysteria2://${PASS}@${IP}:${PORT}/?sni=${SNI}&alpn=h3&insecure=1#Hy2-TLS-2025"
echo ""
echo "⚠️ 客户端用 insecure=1 跳过证书验证（自签证书）。伪装已足够隐蔽，无需 obfs。"
echo "启动服务器（预期日志: INFO listening on :443）..."
exec ./"$BIN" server -c config.yaml
