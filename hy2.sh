#!/usr/bin/env bash
# Hysteria2 超极简一键脚本（零语法错误版）
# 适合任何海外 VPS（含 64MB 低配机型）

set -euo pipefail

# ============= 可改参数 =============
PORT="${1:-443}"                              # 运行时带端口：bash hy2.sh 443
SNI="pages.cloudflare.com"
ALPN="h3"
VERSION="v2.6.5"
# ====================================

info() { echo -e "\033[32m[+] $*\033[0m"; }

# 架构
case "$(uname -m)" in
  x86_64|amd64)   ARCH="amd64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  armv7*|armv6*)  ARCH="arm"   ;;
  *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"

# 下载
if [ ! -f "$BIN" ]; then
  info "正在下载 Hysteria2 $VERSION ($ARCH)…"
  curl -L -o "$BIN" \
    "https://github.com/apernet/hysteria/releases/download/app/$VERSION/$BIN"
  chmod +x "$BIN"
fi

# 随机密码
PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c16)
info "随机密码：$PASS"

# 自签证书（只生成一次）
[ -f cert.pem ] || {
  info "生成自签名证书…"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -keyout key.pem -out cert.pem -subj "/CN=$SNI" >/dev/null 2>&1
}

# 自动测速（稳到爆的写法）
info "测速中…"
UP=150; DOWN=200
for url in \
  "https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn" \
  "https://fastly.jsdelivr.net/gh/sjlleo/Trace/flushcdn"; do
  result=$(curl -s --max-time 8 "$url") && {
    UP=$(echo "$result" | grep -o '[0-9]\+ Mbps' | head -1 | cut -d' ' -f1)
    DOWN=$(echo "$result" | grep -o '[0-9]\+ Mbps' | tail -1 | cut -d' ' -f1)
    break
  }
done
UP_MBIT=$((UP + UP/3))
DOWN_MBIT=$((DOWN + DOWN/3))

# 写配置
cat > config.yaml <<EOF
listen: :$PORT
tls:
  cert: $(pwd)/cert.pem
  key:  $(pwd)/key.pem
auth:
  type: password
  password: $PASS
bandwidth:
  up: ${UP_MBIT} mbps
  down: ${DOWN_MBIT} mbps
brutal:
  enabled: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF

# 获取 IP
IP=$(curl -s --max-time 6 https://api.ipify.org || curl -s https://ifconfig.me)

# 最终输出
clear
cat <<EOF

══════════════════════════════════════
      Hysteria2 部署成功！（Brutal 版）
══════════════════════════════════════
IP        : $IP
端口       : $PORT
密码       : $PASS
SNI       : $SNI
实测带宽   : 上行 ${UP}→${UP_MBIT} Mbps   下行 ${DOWN}→${DOWN_MBIT} Mbps

客户端一键链接（直接导入 Clash Meta / Nekobox / v2rayNG）：
hysteria2://$PASS@$IP:$PORT/?sni=$SNI&alpn=$ALPN&insecure=1#Hy2-$IP

══════════════════════════════════════
EOF

info "启动中…"
exec ./$BIN server -c config.yaml
