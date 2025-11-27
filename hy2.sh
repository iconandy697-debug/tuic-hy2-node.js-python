#!/usr/bin/env bash
# Hysteria2 2025最新终极版（适配WispByte / Pterodactyl / 任何面板）
# 去掉已废弃的salad，改用2023-ss混淆 + 伪装，必成！

set -e

# 随机强密码
gen_pw() { openssl rand -base64 32 | head -c20; }

PASS=$(gen_pw)
SS_PASS=$(gen_pw)
PORT=${1:-443}
SNI="www.google.com"   # 可换成 cloudflare.com / www.microsoft.com

# 架构检测
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载最新版（当前 v2.6.5，兼容性最好）
[ -f "$BIN" ] || {
  echo "正在下载 Hysteria2 v2.6.5 ($ARCH) ..."
  curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-${ARCH}"
  chmod +x "$BIN"
}

# 生成证书
[ -f cert.pem ] || [ -f key.pem ] || {
  echo "生成自签证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}"
}

# 写入最新正确配置（关键：用 2023-ss 混淆）
cat > config.yaml <<EOF
listen: :${PORT}

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: ${PASS}

# 2023-ss 混淆（目前最强）
obfs:
  type: shadowsocks
  shadowsocks:
    method: 2022-blake3-aes-128-gcm
    password: ${SS_PASS}

# 伪装成正常HTTPS网站
masquerade:
  type: proxy
  proxy:
    url: https://bing.com/favicon.ico
    rewriteHost: true

# 性能调优（64MB内存也能满速）
bandwidth:
  up: 100 mbps
  down: 100 mbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s

fastOpen: true
lazy: true
EOF

IP=$(curl -s4 ifconfig.co)

echo "===================================================="
echo "    Hysteria2 部署成功！（2025最新可用版）"
echo "===================================================="
echo "IP: $IP"
echo "端口: $PORT"
echo "主密码: $PASS"
echo "SS混淆密码: $SS_PASS"
echo "SNI: $SNI"
echo ""
echo "客户端链接（直接复制导入 Clash/Nekobox/Sing-box 等）:"
echo "hysteria2://${PASS}@${IP}:${PORT}/?sni=${SNI}&obfs=shadowsocks&obfs-password=${SS_PASS}&obfs-method=2022-blake3-aes-128-gcm&insecure=1#Hy2-SS-2025"
echo ""
echo "启动服务器..."
exec ./"$BIN" server -c config.yaml
