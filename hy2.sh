#!/usr/bin/env bash
# WispByte 静默保活版 Hysteria2 一键部署（2025最新）
# 特点：零交互、随机一切、进程隐藏、CPU<10%、无明显特征
# 用法：curl -Ls https://raw.githubusercontent.com/1eeZ/hy2-wisp/main/hy2.sh | bash

set -e

# ============= 可自定义区（建议保留随机）=============
RANDOM_PORT=$((RANDOM % 40000 + 20000))      # 20000-60000 随机端口
RANDOM_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
RANDOM_NAME=$(tr -dc a-z0-9 </dev/urandom | head -c 12)
SNI_LIST=("www.bing.com" "www.microsoft.com" "update.microsoft.com" "www.apple.com" "pub.alibabacloud.com" "www.cloudflare.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}
ALPN_LIST=("h3" "h3,h2")
ALPN=${ALPN_LIST[$RANDOM % ${#ALPN_LIST[@]}]}
# ===================================================

HYSTERIA_VERSION="v2.6.5"
ARCH=$(uname -m | tr '[:upper:]' '[:lower:]')
case $ARCH in
    aarch64|arm64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

# 随机假进程名（关键！）
FAKE_NAME="/usr/bin/${RANDOM_NAME}"
BIN_PATH="${FAKE_NAME}"

# 完全静默下载
download_silently() {
    [ -f "$BIN_PATH" ] && return
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${ARCH}"
    mkdir -p /tmp/.cache 2>/dev/null
    curl -sL --connect-timeout 20 --max-time 60 --retry 3 "$URL" -o "$BIN_PATH"
    chmod +x "$BIN_PATH" 2>/dev/null
}

# 生成自签证书（静默）
gen_cert() {
    [ -f /tmp/.cache/cert.pem ] && [ -f /tmp/.cache/key.pem ] && return
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /tmp/.cache/key.pem -out /tmp/.cache/cert.pem -subj "/CN=${SNI}" -days 3650 >/dev/null 2>&1
}

# 写入极低 CPU 配置（关键！）
write_config() {
cat > /tmp/.cache/hy2.yaml <<EOF
listen: :${RANDOM_PORT}
tls:
  cert: /tmp/.cache/cert.pem
  key: /tmp/.cache/key.pem
  alpn:
    - ${ALPN}
auth:
  type: password
  password: ${RANDOM_PASS}
bandwidth:
  up: 50mbps      # 故意压低，降低特征
  down: 100mbps
quic:
  initCongestionWindow: 20
  maxCongestionWindow: 60
  maxIdleTimeout: 15s
  maxConcurrentStreams: 3
  initialStreamReceiveWindow: 65536
  maxStreamReceiveWindow: 65536
  initialConnReceiveWindow: 131072
  maxConnReceiveWindow: 131072
disableUDP: false
fastOpen: true
lazyStart: true
EOF
}

# 获取公网IP（静默）
get_ip() {
    curl -s --max-time 8 https://api.ipify.org || curl -s --max-time 8 https://ifconfig.me
}

main() {
    download_silently
    gen_cert
    write_config
    
    IP=$(get_ip)
    
    # 启动时完全隐藏（复制到随机名字 + nohup + 重定向所有输出）
    nohup "$BIN_PATH" server -c /tmp/.cache/hy2.yaml >/dev/null 2>&1 &
    
    # 等待3秒确保启动
    sleep 3
    
    # 只输出一次连接信息，然后自删脚本（防面板日志）
    echo "Hysteria2 部署完成（已静默运行）"
    echo "============================================"
    echo "IP: $IP"
    echo "端口: $RANDOM_PORT"
    echo "密码: $RANDOM_PASS"
    echo "SNI: $SNI"
    echo "ALPN: $ALPN"
    echo ""
    echo "导入链接（跳过证书验证）:"
    echo "hysteria2://${RANDOM_PASS}@${IP}:${RANDOM_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Wisp-Hy2"
    echo "============================================"
    
    # 关键：部署完成后立即删除自身（防止被面板扫描到脚本内容）
    history -c 2>/dev/null
    rm -f $0
}

main
