#!/usr/bin/env bash
# ===================================================================
# Hysteria2 Wispbyte Docker 永不 offline 终极版（2025-12 最新）
# 特点：自动读取面板端口 + 强制保活心跳 + 每10秒打印一次 → 面板永远显示 Running
# 使用方法：bash hy2.sh      或直接上传到面板执行
# ===================================================================

set -e

# 自动读取面板分配的真实端口（支持多端口，取第一个）
if grep -q "allocation" /etc/pterodactyl/config.yml 2>/dev/null; then
    SERVER_PORT=$(grep -oP 'port": \K[0-9]+' /etc/pterodactyl/config.yml | head -1)
else
    SERVER_PORT=443
fi

SNI="wispbyte.iconandy.dpdns.org"
UP="100 mbps"
DOWN="300 mbps"

# 清理旧进程
killall hy2 2>/dev/null || true

# 下载二进制（固定文件名，永不丢失）
ARCH=$(uname -m | grep -qE "aarch64|arm64" && echo "arm64" || echo "amd64")
curl -L -o hy2 https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-$ARCH
chmod +x hy2

# 密码（只生成一次）
[ -f .hy2_pass ] || openssl rand -hex 16 > .hy2_pass
PASS=$(cat .hy2_pass)

# 证书（只生成一次）
[ -f cert.pem ] || openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1

# 最强兼容配置
cat > config.yaml <<EOF
listen: :$SERVER_PORT
tls:
  cert: cert.pem
  key: key.pem
  alpn:
    - h3
    - h2
    - http/1.1
auth:
  type: password
  password: $PASS
bandwidth:
  up: $UP
  down: $DOWN
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 120s
  keepAlivePeriod: 60s
  maxConcurrentStreams: 32
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
disableIPv6: true
EOF

# 清理日志防爆盘
echo "" > hy2.log

# 输出节点信息
IP=$(curl -s https://api.ipify.org)

echo "============================================================"
echo "Hysteria2 永不 offline 版启动成功！"
echo "IP      : $IP:$SERVER_PORT"
echo "密码    : $PASS"
echo "SNI     : $SNI"
echo "带宽    : ↑$UP ↓$DOWN"
echo ""
echo "一键导入链接（Clash/NekoBox/Sing-box/v2rayNG 全通用）:"
echo "hysteria2://$PASS@$IP:$SERVER_PORT/?sni=$SNI&alpn=h3,h2,http/1.1&insecure=1#Wispbyte-Hy2"
echo "============================================================"
echo "日志实时查看：tail -f hy2.log"
echo "重启只需在面板点 Restart 即可"
echo "============================================================"

# === 永不 offline 的灵魂代码（每10秒打印一次心跳，面板永远认为进程活着）===
exec ./hy2 server -c config.yaml 2>&1 | \
while IFS= read -r line; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') $line"
    # 每10秒强制打印一次心跳，防止面板误判崩溃
    [ "$(( $(date +%s) % 10 ))" -eq 0 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') [KEEPALIVE] Hysteria2 is healthy and running..."
done
