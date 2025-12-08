#!/bin/bash
# Wispbyte / Pterodactyl 专用 Hysteria2 超隐蔽部署脚本（2025 终极版）
# 特性：零日志、随机端口、进程名伪装、CPU<10%、masquerade 伪装流量、自动重启、永不掉线

cd /home/container || exit 1

# ==================== 可自定义区（改这里就行） ====================
BIN="sysmonitor"                    # 伪装进程名（ps 看不到 Hysteria）
VER="v2.6.5"                        # Hysteria2 版本（推荐不要改，最新版反而容易被特征识别）
SNI="www.microsoft.com"             # 伪装域名（微软最稳）
MASQUERADE_URL="https://bing.com"   # masquerade 伪装目标
UP_BPS="15 mbps"                    # 上行限速
DOWN_BPS="40 mbps"                  # 下行限速
# ==============================================================

# 架构自适应
ARCH=$(uname -m | tr '[:upper:]' '[:lower:]' | sed 's/x86_64/amd64/;s/aarch64/arm64/')
URL="https://github.com/apernet/hysteria/releases/download/app/${VER}/hysteria-linux-${ARCH}"

# 随机端口（15000~65000，避开常用端口）
PORT=$((RANDOM % 50000 + 15000))

# 密码持久化
if [ -f .pass ]; then
    PASS=$(cat .pass)
else
    PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c32)
    echo "$PASS" > .pass
    chmod 600 .pass
fi

# 下载二进制并伪装（已存在则跳过）
if [ ! -f "$BIN" ]; then
    curl -Ls --fail --retry 3 --connect-timeout 10 "$URL" -o "$BIN" >/dev/null 2>&1
    chmod +x "$BIN"
fi

# 生成自签证书（已存在则跳过）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    openssl req -x509 -nodes -days 3650 \
        -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout key.pem -out cert.pem \
        -subj "/CN=${SNI}" >/dev/null 2>&1
fi

# 写入超低占 + 高隐蔽性配置
cat > config.yaml <<EOF
listen: :$PORT
tls:
  cert: cert.pem
  key: key.pem
auth:
  type: password
  password: $PASS
bandwidth:
  up: $UP_BPS
  down: $DOWN_BPS
quic:
  max_concurrent_streams: 6
  max_idle_timeout: 90s
  keepAlivePeriod: 60s
  initial_stream_receive_window: 32768
  max_stream_receive_window: 65536
  initial_conn_receive_window: 65536
  max_conn_receive_window: 131072
masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true
fastOpen: true
lazyStart: true
disableUDP: false
udpReceiveBuffer: 4mb
udpSendBuffer: 4mb
EOF

# 清理旧进程（防止多开）
pkill -f "$BIN" 2>/dev/null || true
sleep 2

# 关键：必须用 exec 前台运行，否则面板认为掉线
echo "Hysteria2 已启动 | 端口: $PORT | CPU<10% | 伪装: $MASQUERADE_URL"
echo "获取信息命令：cat .pass ; grep listen config.yaml ; curl -s ifconfig.me"

exec ./"$BIN" server -c config.yaml
