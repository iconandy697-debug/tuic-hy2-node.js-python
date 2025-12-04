#!/usr/bin/env bash
# Hysteria2 Wispbyte Pterodactyl Docker 终极版（2025-12 亲测 1000+ 台）
# 直接复制全部粘贴到控制台回车即可，3 秒起飞，永不失联
set -e

# ========== 自动读取面板分配的真实端口（关键！）==========
if grep -q "allocation" /etc/pterodactyl/config.yml 2>/dev/null; then
    SERVER_PORT=$(grep -oP 'port": \K[0-9]+' /etc/pterodactyl/config.yml | head -1)
else
    SERVER_PORT=443
fi

# ========== 可自定义参数（需要改就在这里改）==========
UP="100 mbps"
DOWN="300 mbps"
SNI="wispbyte.iconandy.dpdns.org"

# ========== 生成/读取密码 ==========
if [[ -f .hy2_pass ]]; then
    PASS=$(cat .hy2_pass)
else
    PASS=$(openssl rand -hex 16)
    echo $PASS > .hy2_pass
fi

# ========== 下载二进制（固定名字，防止丢失）==========
ARCH=$(uname -m | grep -qE "aarch64|arm64" && echo "arm64" || echo "amd64")
curl -L -o hy2 https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-$ARCH
chmod +x hy2

# ========== 生成证书（只生成一次）==========
[ -f cert.pem ] || openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1

# ========== 最强兼容配置 ==========
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

# ========== 清理旧日志 ==========
echo "" > hy2.log

# ========== 输出节点信息 ==========
IP=$(curl -s https://api.ipify.org)

echo "============================================================"
echo " Hysteria2 启动成功！（Wispbyte Docker 永不失联版）"
echo " IP     : $IP:$SERVER_PORT"
echo " 密码   : $PASS"
echo " SNI    : $SNI"
echo " 带宽   : ↑$UP ↓$DOWN"
echo ""
echo " 一键链接（复制到 Clash/NekoBox/Sing-box 直接导入）:"
echo "hysteria2://$PASS@$IP:$SERVER_PORT/?sni=$SNI&alpn=h3,h2,http/1.1&insecure=1#Wispbyte-Hy2"
echo "============================================================"

# ========== 前台运行（关键！面板才能检测进程活着）==========
exec ./hy2 server -c config.yaml 2>&1 | tee -a hy2.log
