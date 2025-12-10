#!/usr/bin/env bash
# WispByte 静默保活版 Hysteria2 一键部署（2025最新·强制留链接版）
# 改动点：除了终端输出外，还同时写入 /root/hy2.txt 和 /tmp/.hy2_link（兼容各种奇葩面板）

set -e

# ============= 可自定义区 =============
RANDOM_PORT=$((RANDOM % 40000 + 20000))
RANDOM_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
RANDOM_NAME=$(tr -dc a-z0-9 </dev/urandom | head -c 12)
SNI_LIST=("www.bing.com" "www.microsoft.com" "update.microsoft.com" "www.apple.com" "pub.alibabacloud.com" "www.cloudflare.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}
ALPN_LIST=("h3" "h3,h2")
ALPN=${ALPN_LIST[$RANDOM % ${#ALPN_LIST[@]}]}
# ======================================

HYSTERIA_VERSION="v2.6.5"
ARCH=$(uname -m | tr '[:upper:]' '[:lower:]')
case $ARCH in
    aarch64|arm64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

FAKE_NAME="/usr/bin/${RANDOM_NAME}"
BIN_PATH="${FAKE_NAME}"

download_silently() {
    [ -f "$BIN_PATH" ] && return
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${ARCH}"
    mkdir -p /tmp/.cache 2>/dev/null
    curl -sL --connect-timeout 20 --max-time 60 --retry 3 "$URL" -o "$BIN_PATH"
    chmod +x "$BIN_PATH" 2>/dev/null
}

gen_cert() {
    [ -f /tmp/.cache/cert.pem ] && [ -f /tmp/.cache/key.pem ] && return
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /tmp/.cache/key.pem -out /tmp/.cache/cert.pem -subj "/CN=${SNI}" -days 3650 >/dev/null 2>&1
}

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
  up: 50mbps
  down: 100mbps
quic:
  initCongestionWindow: 20
  maxCongestionWindow: 60
  maxIdleTimeout: 15s
  maxConcurrentStreams: 3
disableUDP: false
fastOpen: true
lazyStart: true
EOF
}

get_ip() {
    curl -s --max-time 8 https://api.ipify.org || curl -s --max-time 8 https://ifconfig.me || echo "127.0.0.1"
}

# 关键函数：把链接同时写入多个位置，保证你一定能看到
save_and_show_link() {
    local ip=$1
    local link="hysteria2://${RANDOM_PASS}@${ip}:${RANDOM_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Wisp-Hy2"

    # 1. 正常终端输出（某些面板能看到）
    echo "Hysteria2 部署完成（已静默运行）"
    echo "============================================"
    echo "IP: $ip"
    echo "端口: $RANDOM_PORT"
    echo "密码: $RANDOM_PASS"
    echo "SNI: $SNI"
    echo "ALPN: $ALPN"
    echo ""
    echo "导入链接（跳过证书验证）:"
    echo "$link"
    echo "============================================"

    # 2. 强制写入文件（WispByte 必看这里！）
    mkdir -p /root 2>/dev/null
    cat > /root/hy2.txt <<EOF
Hysteria2 连接信息（$(date +"%Y-%m-%d %H:%M:%S")）
IP: $ip
端口: $RANDOM_PORT
密码: $RANDOM_PASS
SNI: $SNI
ALPN: $ALPN
链接: $link
EOF

    # 3. 再写一份到 /tmp，防止某些面板禁写 /root
    cat > /tmp/.hy2_link <<EOF
$link
EOF

    # 4. 再写一份到当前目录，兼容手动 bash 运行
    echo "$link" > ./hy2_link.txt 2>/dev/null || true

    echo "连接信息已同时保存到以下位置（随便找一个看就行）：
    /root/hy2.txt
    /tmp/.hy2_link
    当前目录 hy2_link.txt"
}

main() {
    download_silently
    gen_cert
    write_config
    
    IP=$(get_ip)
    
    nohup "$BIN_PATH" server -c /tmp/.cache/hy2.yaml >/dev/null 2>&1 & disown
    
    sleep 4
    
    # 核心：把链接同时输出到终端 + 写文件
    save_and_show_link "$IP"
    
    # 清理历史记录和自身（可选，保留链接文件）
    history -c 2>/dev/null || true
    rm -f "$0" 2>/dev/null || true
}

main
