#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 无 systemd 专用版（完美适配 Wispbyte / 所有禁 systemd 的 OpenVZ）
# 2025 年最新稳态版，32MB 内存长年不崩
set -euo pipefail

HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="wispbyte.iconandy.dpdns.org"   # 随便填一个常用 CDN 域名即可

# 带宽可通过环境变量覆盖
UP_BW="${UP:-50mbps}"
DOWN_BW="${DOWN:-100mbps}"

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  Hysteria2 无 systemd 专用版（Wispbyte / OpenVZ 神器）"
echo "  用法：bash $0 443        或    UP=100 DOWN=300 bash $0 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ========== 端口 ==========
if [[ $# -ge 1 ]] && [[ -n "$1" ]]; then
    SERVER_PORT="$1"
else
    SERVER_PORT="$DEFAULT_PORT"
fi
echo "使用端口: $SERVER_PORT"

# ========== 架构 ==========
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="/usr/local/bin/hysteria"

# ========== 防止重复运行 ==========
if screen -list | grep -q "hy2"; then
    echo "Hysteria2 已经在 screen 会话中运行，阻止重复启动"
    exit 0
fi

# ========== 密码 ==========
if [[ -f ".hy2_pass" ]] && [[ -s ".hy2_pass" ]]; then
    AUTH_PASSWORD="$(cat .hy2_pass)"
else
    AUTH_PASSWORD="$(openssl rand -hex 16)"
    echo "$AUTH_PASSWORD" > .hy2_pass
    chmod 600 .hy2_pass
fi

# ========== 二进制 ==========
if [[ ! -f "$BIN_PATH" ]] || [[ "$($BIN_PATH version 2>/dev/null | head -n1 | awk '{print $3}')" != "${HYSTERIA_VERSION#v}" ]]; then
    echo "正在更新 Hysteria2 二进制..."
    curl -L -o "$BIN_PATH" "https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    chmod +x "$BIN_PATH"
fi

# ========== 证书 ==========
if [[ ! -f "$CERT_FILE" ]] || [[ ! -f "$KEY_FILE" ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1
    chmod 600 "$KEY_FILE"
fi

# ========== 配置文件 ==========
cat > server.yaml <<EOF
listen: :$SERVER_PORT

tls:
  cert: $(pwd)/$CERT_FILE
  key: $(pwd)/$KEY_FILE
  alpn:
    - h3
    - h2
    - http/1.1

auth:
  type: password
  password: $AUTH_PASSWORD

bandwidth:
  up: $UP_BW
  down: $DOWN_BW

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 120s
  keepAlivePeriod: 60s
  maxConcurrentStreams: 16

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

disableIPv6: true
EOF

# ========== 停止旧进程（如果有）==========
screen -wipe >/dev/null 2>&1
screen -dmS hy2 bash -c "echo 'Hysteria2 启动中...' && $BIN_PATH server -c server.yaml >> hy2.log 2>&1"

# ========== 日志防爆盘（每天清理一次）==========
cat > /etc/cron.daily/clean_hy2_log <<'EOF'
#!/bin/sh
echo "" > /root/hy2.log 2>/dev/null || true
find /root -name "hy2.log.*" -mtime +3 -delete 2>/dev/null || true
EOF
chmod +x /etc/cron.daily/clean_hy2_log

# ========== 防止意外退出自动重启（crontab 兜底）==========
(crontab -l 2>/dev/null | grep -v "hy2_restart.sh"; echo "*/3 * * * * /bin/bash $(pwd)/hy2_restart.sh >/dev/null 2>&1") | crontab -

cat > hy2_restart.sh <<'EOF'
#!/bin/bash
if ! screen -list | grep -q "hy2"; then
    cd "$(dirname "$0")"
    screen -dmS hy2 bash -c "/usr/local/bin/hysteria server -c server.yaml >> hy2.log 2>&1"
fi
EOF
chmod +x hy2_restart.sh

# ========== 输出信息 ==========
IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)

echo "============================================================"
echo "Hysteria2 已启动（screen 会话名：hy2）"
echo "IP      : $IP"
echo "端口    : $SERVER_PORT"
echo "密码    : $AUTH_PASSWORD"
echo "SNI     : $SNI"
echo "带宽    : 上行 $UP_BW  下行 $DOWN_BW"
echo ""
echo "节点链接（通用）:"
echo "hysteria2://$AUTH_PASSWORD@$IP:$SERVER_PORT/?sni=$SNI&alpn=h3,h2,http/1.1&insecure=1#Wispbyte-Hy2"
echo ""
echo "查看日志     : screen -r hy2    或    tail -f hy2.log"
echo "停止服务     : screen -X -S hy2 quit"
echo "重启服务     : screen -X -S hy2 quit && bash $0 $SERVER_PORT"
echo "============================================================"

exit 0
