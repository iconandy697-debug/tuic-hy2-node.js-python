#!/usr/bin/env bash
# Hysteria2 2025 最终极简可运行版（WispByte 64MB 专用）
# 直接复制运行，零错误，带自动下载

set -e

# 随机密码
PASS=$(openssl rand -base64 32 | head -c20)
PORT=${1:-443}
SNI="www.google.com"

# 自动识别架构
case "$(uname -m)" in
  x86_64|amd64)   ARCH="amd64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 1. 下载二进制（关键！）
if [ ! -f "$BIN" ]; then
  echo "正在下载 Hysteria2 v2.6.5 ($ARCH)..."
  curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}"
  chmod +x "$BIN"
fi

# 2. 生成自签证书
IP=$(curl -s4 ifconfig.co)
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  echo "生成自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -subj "/CN=${SNI}" \
    -addext "subjectAltName=DNS:${SNI},IP:${IP}" 2>/dev/null
fi

# 3. 写入配置
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
bandwidth:
  up: 50 mbps
  down: 100 mbps
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
fastOpen: true
lazy: true
EOF

echo "===================================================="
echo "     Hysteria2 部署完成！"
echo "IP     : $IP"
echo "端口   : $PORT"
echo "密码   : $PASS"
echo "链接   : hysteria2://${PASS}@${IP}:${PORT}/?sni=${SNI}&alpn=h3&insecure=1#Hy2"
echo "===================================================="
echo "启动中..."
exec ./"$BIN" server -c config.yaml
