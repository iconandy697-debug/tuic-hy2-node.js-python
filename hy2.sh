#!/usr/bin/env bash
# WispByte 静默保活版 Hysteria2 一键部署（2025最新·可显示链接版）
# 专为 WispByte / 类似只读面板优化，连接信息会写入面板 log 永久可见

set -e

# ============= 可自定义区（建议保留随机）=============
RANDOM_PORT=$((RANDOM % 40000 + 20000))
RANDOM_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
RANDOM_NAME=$(tr -dc a-z0-12 </dev/urandom | head -c 12)
SNI_LIST=("www.bing.com" "www.microsoft.com" "update.microsoft.com" "www.apple.com" "pub.alibabacloud.com" "www.cloudflare.com" "edges.microsoft.com")
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

FAKE_NAME="/usr/bin/${RANDOM_NAME}"
BIN_PATH="${FAKE_NAME}"

# 寻找 WispByte 面板真正的 log 路径（2024-2025 常用路径全覆盖）
find_log_path() {
    for path in \
        "/home/$(whoami)/log" \
        "/home/log" \
        "/home/*/log" \
        "/home/web/log" \
        "/home/container/log" \
        "$(pwd)/log" \
        "/tmp"; do
        if mkdir -p "$path" 2>/dev/null && touch "$path/.test" 2>/dev/null; then
            rm -f "$path/.test"
            echo "$path"
            return
        fi
    done
    echo "/tmp"  # 最后保底
}

LOG_DIR=$(find_log_path)
LOG_FILE="$LOG_DIR/hysteria2_wispbyte_$(date +%Y%m%d).log"

download_silently() {
    [ -f "$BIN_PATH" ] && return
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${ARCH}"
    mkdir -p /tmp/.cache 2>/dev/null
    curl -sL --connect-timeout 20 --max-time 60 --retry 5 "$URL" -o "$BIN_PATH"
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
  down: 120mbps
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
    curl -s --max-time 8 https://api.ipify.org || curl -s --max-time 8 https://ifconfig.me || echo "0.0.0.0"
}

main() {
    download_silently
    gen_cert
    write_config
    
    IP=$(get_ip)
    
    # 先把连接信息写进面板能看到的 log（多次写入防面板刷新丢失）
    {
        echo "============================================"
        echo "Hysteria2 已成功部署并静默运行（$(date '+%Y-%m-%d %H:%M:%S')）"
        echo "服务器IP : $IP"
        echo "端口      : $RANDOM_PORT"
        echo "密码      : $RANDOM_PASS"
        echo "SNI       : $SNI"
        echo "ALPN      : $ALPN"
        echo ""
        echo "【一键导入链接（跳过证书验证）】"
        echo "hysteria2://${RANDOM_PASS}@${IP}:${RANDOM_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#WispByte-Hy2"
        echo ""
        echo "进程已伪装为: $FAKE_NAME   CPU占用极低，可长期存活"
        echo "============================================"
        echo ""
    } | tee "$LOG_FILE" > /dev/null
    
    # 再额外写一份到 /tmp，防止某些面板只显示 /tmp 的垃圾面板
    cat "$LOG_FILE" > /tmp/.hy2_success_$(date +%s).txt 2>/dev/null || true
    
    # 启动 Hysteria2（完全后台 + 隐藏）
    nohup "$BIN_PATH" server -c /tmp/.cache/hy2.yaml >/dev/null 2>&1 &
    
    # 再次把链接打进标准输出，防止某些面板只看最后几行
    cat "$LOG_FILE"
    
    # 清理历史记录 + 自删脚本（保留 log 文件！）
    history -c 2>/dev/null || true
    rm -f "$0"
}

main
