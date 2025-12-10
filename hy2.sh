#!/usr/bin/env bash
# 2025 最终保活版 Hysteria2 — 专治 WispByte/Pterodactyl 重启后仍能看到链接
set -e

# 随机参数
PORT=$((RANDOM % 40000 + 20000))
PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
SNI_LIST=("www.bing.com" "www.microsoft.com" "update.microsoft.com" "www.apple.com" "www.cloudflare.com" "edges.microsoft.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}
ALPN="h3"

# 架构
case $(uname -m) in
    aarch64|arm64) ARCH=arm64 ;;
    *)             ARCH=amd64 ;;
esac

# 路径（全部放最保险的位置）
BIN="/usr/local/bin/$(tr -dc a-z0-9 </dev/urandom | head -c 18)"
CFG="/tmp/hy2_$(tr -dc a-z0-9 </dev/urandom | head -c 10).yaml"

# 下载本体
curl -fsSL --retry 5 --connect-timeout 15 \
    "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-$ARCH" \
    -o "$BIN"
chmod +x "$BIN"

# 自签证书
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
    -subj "/CN=$SNI" -nodes -keyout /tmp/k.pem -out /tmp/c.pem 2>/dev/null

# 配置文件（极低特征）
cat > "$CFG" <<EOF
listen: :$PORT
tls:
  cert: /tmp/c.pem
  key: /tmp/k.pem
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

# 公网IP
IP=$(curl -m 8 -fsSL https://api.ipify.org || curl -m 8 -fsSL https://ifconfig.me)

# 连接信息
LINK="hysteria2://$PASS@$IP:$PORT/?sni=$SNI&alpn=$ALPN&insecure=1#WispByte-Hy2"

# 超级暴力输出函数
success() {
    cat <<EOF

═══════════════════════════════════════════════════════════
Hysteria2 成功启动！$(date '+%Y-%m-%d %H:%M:%S')
IP      → $IP
端口    → $PORT
密码    → $PASS
SNI     → $SNI
链接    → $LINK
═══════════════════════════════════════════════════════════

EOF
}

# 狂写所有可能位置
for p in /tmp /dev/shm . ./log ../log; do
    for f in hy2.txt hysteria2.log .hy2 .link; do
        success >> "$p/$f" 2>/dev/null || true
    done
done

# 标准输出刷屏 18 次（WispByte/Pterodactyl 必看这里）
for i in {1..18}; do
    success
    sleep 0.12
done

# 启动
nohup "$BIN" server -c "$CFG" >/dev/null 2>&dev/null &

# 再刷两次防被冲
sleep 1
success
success

# 清理
rm -f "$0" 2>/dev/null || true

exit 0
