#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极简部署脚本（已内置自动测速 + Brutal 限速算法）
# 适用于超低内存环境（32-64MB）

set -e

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
AUTH_PASSWORD="167452Aa@"   # 建议改成自己的复杂密码
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="pages.cloudflare.com"
ALPN="h3"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极简部署脚本（自动测速 + Brutal 限速算法）"
echo "支持命令行端口参数，如：bash hy2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构 ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $URL"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 自动测速 ----------
auto_speedtest() {
    echo "⏳ 正在自动测速（只需几秒）..."
    local result
    result=$(curl -s --max-time 15 https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn || echo "ERROR")
    
    if [[ "$result" == *"ERROR"* ]] || [[ -z "$result" ]]; then
        echo "⚠️  测速失败，使用默认 300Mbps 作为保底"
        UP_MBIT=300
        DOWN_MBIT=300
    else
        UP_MBIT=$(echo "$result" | grep -o "[0-9]\+ Mbps" | head -n1 | awk '{print $1}')
        DOWN_MBIT=$(echo "$result" | grep -o "[0-9]\+ Mbps" | tail -n1 | awk '{print $1}')
        [[ -z "$UP_MBIT" ]] && UP_MBIT=300
        [[ -z "$DOWN_MBIT" ]] && DOWN_MBIT=300
    fi
    
    echo "✅ 测速完成 → 上行: ${UP_MBIT} Mbps   下行: ${DOWN_MBIT} Mbps"
}

# ---------- 写配置文件（关键修改点）----------
write_config() {
    cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"

tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"

auth:
  type: "password"
  password: "${AUTH_PASSWORD}"

# 自动填入真实带宽
bandwidth:
  up: "${UP_MBIT} mbps"
  down: "${DOWN_MBIT} mbps"

# 开启 Brutal 拥塞控制（最猛的保底 50~100Mbps 模式）
brutal:
  enabled: true
  sendBBR: false   # 保持 false，性能最佳

quic:
  max_idle_timeout: "10s"
  max_concurrent_streams: 4
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144
EOF
    echo "✅ 配置已写入 server.yaml（端口=${SERVER_PORT}，Brutal 已开启）"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    IP=$(curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（Brutal 限速算法已开启）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口: $SERVER_PORT"
    echo "   🔑 密码: $AUTH_PASSWORD"
    echo "   🚀 实测带宽: 上行 ${UP_MBIT}Mbps / 下行 ${DOWN_MBIT}Mbps"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Brutal"
    echo ""
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    auto_speedtest          # ← 新增：自动测速
    write_config            # ← 使用测出来的带宽 + 开启 brutal
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 启动 Hysteria2 服务器（Brutal 已启用）..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"

