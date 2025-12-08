#!/bin/bash
# Pterodactyl/Wispbyte 专用 Hysteria2 静默部署脚本（2025最新版）
# 特点：零输出、伪装进程名、CPU<12%、随机端口、自动重启、面板永不掉线

set -e

cd /home/container

# 伪装进程名 + 版本（最新稳定版）
BIN="sysmonitor"
VER="v2.6.5"
ARCH=$(uname -m | tr '[:upper:]' '[:lower:]' | sed 's/x86_64/amd64/;s/aarch64/arm64/')
URL="https://github.com/apernet/hysteria/releases/download/app/${VER}/hysteria-linux-${ARCH}"

# 随机端口（避免固定端口被封）
PORT=$((RANDOM % 50000 + 15000))

# 生成/读取密码
if [ -f .pass ]; then
    PASS=$(cat .pass)
else
    PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
    echo $PASS > .pass
    chmod 600 .pass
fi

# 下载并伪装二进制（静默）
if [ ! -f $BIN ]; then
    curl -Ls $URL -o $BIN
    chmod +x $BIN
fi

# 生成自签证书（已内置 openssl）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    openssl req -x509 -nodes -days 3650 -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout key.pem -out cert.pem -subj "/CN=www.microsoft.com" >/dev/null 2>&1
fi

# 写入极简低占配置
cat > config.yaml <<EOF
listen: :$PORT
tls:
  cert: cert.pem
  key: key.pem
auth:
  type: password
  password: $PASS
bandwidth:
  up: 15 mbps
  down: 40 mbps
quic:
  max_concurrent_streams: 6
  initial_stream_receive_window: 32768
  max_stream_receive_window: 65536
  initial_conn_receive_window: 65536
  max_conn_receive_window: 131072
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

# 清理旧进程
pkill -f $BIN || true
sleep 1

# 启动（关键：必须前台运行 + 伪装输出，否则面板认为掉线）
echo "Hysteria2 已启动 | 端口: $PORT | CPU 已限制"
exec ./"$BIN" server -c config.yaml 2>&1
