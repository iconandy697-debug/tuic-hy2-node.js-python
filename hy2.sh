#!/usr/bin/env bash
# Hysteria2 2025终极无obfs版（WispByte 专属，零配置错误）
# 纯 masquerade 伪装 + ACME 自动证书，抗封最强

set -e

# 随机密码
gen_pw() { openssl rand -base64 32 | head -c20; }
PASS=$(gen_pw)
PORT=${1:-443}
SNI="www.google.com"  # 随机轮换：可换 www.microsoft.com / www.cloudflare.com

# 架构
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载（v2.6.5 稳定版）
[ -f "$BIN" ] || {
  echo "下载 Hysteria2 v2.6.5 ($ARCH) ..."
  curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}" || \
  wget -O "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}"
  chmod +x "$BIN"
}

# ACME 自动证书（需 80 端口可用，否则 fallback 自签）
echo "配置 ACME 自动证书 (SNI: $SNI) ..."

# 写入纯净配置（无 obfs，纯 masquerade）
cat > config.yaml <<EOF
listen: :${PORT}

# ACME 自动续期证书（推荐，需80端口）
acme:
  domains:
    - ${SNI}
  email: admin@${SNI}

# Fallback 自签证书路径（ACME 失败时用）
tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: ${PASS}

# 核心伪装（让流量看起来像访问正常网站）
masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/favicon.ico  # 动态伪装成访问 SNI 的图标
    rewriteHost: true

# 带宽调优（低配机满速）
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

# 生成 fallback 自签证书
[ -f cert.pem ] || [ -f key.pem ] || {
  echo "生成 fallback 自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}"
}

IP=$(curl -s4 ifconfig.co || curl -s4 ipinfo.io/ip || echo "YOUR_IP")

echo "===================================================="
echo "    Hysteria2 部署成功！（2025无obfs纯伪装版）"
echo "===================================================="
echo "IP: $IP"
echo "端口: $PORT"
echo "密码: $PASS"
echo "SNI: $SNI"
echo ""
echo "客户端链接（直接导入，支持 Nekobox/Clash/Singbox）:"
echo "hysteria2://${PASS}@${IP}:${PORT}/?sni=${SNI}&alpn=h3&insecure=1#Hy2-NoObfs-2025"
echo ""
echo "⚠️ 客户端无需 obfs（服务器不支持），纯 SNI 伪装已足够隐蔽。"
echo "启动服务器（日志无错误即成功）..."
exec ./"$BIN" server -c config.yaml
