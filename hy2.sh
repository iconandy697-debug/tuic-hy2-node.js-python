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
case "$(uname -m)" in
  x86_64|amd64)   ARCH="amd64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载二进制
[ -f "$BIN" ] || {
  echo "正在下载 Hysteria2 v2.6.5 ($ARCH)..."
  curl -L --fail --retry 3 -o "$BIN" \
    "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}"
  chmod +x "$BIN"
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
