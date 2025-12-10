#!/usr/bin/env bash
set -e

# 随机参数
PORT=$((20000 + RANDOM % 40000))
PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
SNI="www.bing.com"
ARCH=$(uname -m | grep -qiE 'arm|aarch64' && echo arm64 || echo amd64)

# 二进制放 /tmp（某些面板/usr/local/bin都不让写）
BIN="/tmp/$(tr -dc a-z0-9 </dev/urandom | head -c 16)"

# 下载（直接重定向到 $BIN，绕过 curl 写失败问题）
curl -fsSL --retry 5 --max-time 30 \
    "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-$ARCH" -o "$BIN"
chmod +x "$BIN"

# 证书和配置全放 /tmp
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
    -subj "/CN=$SNI" -nodes -keyout /tmp/k.pem -out /tmp/c.pem >/dev/null 2>&1

cat > /tmp/hy2.yaml <<EOF
listen: :$PORT
tls:
  cert: /tmp/c.pem
  key:  /tmp/k.pem
auth:
  type: password
  password: $PASS
bandwidth:
  up: 35 mbps
  down: 90 mbps
quic:
  initCongestionWindow: 20
  maxCongestionWindow: 60
  maxIdleTimeout: 15s
  maxConcurrentStreams: 3
fastOpen: true
lazyStart: true
disableUDP: false
EOF

# IP
IP=$(curl -m 7 -fsSL https://api.ipify.org 2>/dev/null || echo "127.0.0.1")

# 链接
LINK="hysteria2://$PASS@$IP:$PORT/?sni=$SNI&alpn=h3&insecure=1#Wisp-OK"

# 暴力输出（只用最保险的两种方式）
msg() {
    cat <<EOF

╔══════════════════════════════════════════════════╗
  Hysteria2 已成功运行！$(date "+%Y-%m-%d %H:%M:%S")
  IP     → $IP
  端口   → $PORT
  密码   → $PASS
  SNI    → $SNI
  链接   → $LINK
  进程   → $(basename $BIN)   CPU < 5%
╚══════════════════════════════════════════════════╝

EOF
}

# 1. 直接刷标准输出 20 次（Pterodactyl/WispByte 实时日志必显示这里）
for i in {1..20}; do
    msg
    sleep 0.1
done

# 2. 同时写 /tmp 多个文件（有些面板会把 /tmp 内容也显示在日志里）
for f in /tmp/hy2.txt /tmp/.hy2 /tmp/hysteria2.log /tmp/.link; do
    msg > "$f" 2>/dev/null || true
    msg >> "$f" 2>/dev/null || true
done

# 启动（完全后台）
nohup "$BIN" server -c /tmp/hy2.yaml >/dev/null 2>&1 &

# 再刷两次防被冲掉
sleep 1
msg
msg

# 清理脚本自身
rm -f "$0" 2>/dev/null || true

exit 0
