#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极简部署脚本（稳态与低占用优化版 + 守护进程）
# 适用于超低内存环境（32-64MB），自动密码、CPU保护、差网稳态、后台守护

set -euo pipefail

# ---------- 基础配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="www.wispbyte.iconandy.dpdns.org"
ALPN="h3"

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 稳态优化部署脚本（Shell 版）"
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

# ---------- 架构检测 ----------
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

# ---------- 生成/读取强密码 ----------
ensure_password() {
    if [[ -f ".hy2_pass" && -s ".hy2_pass" ]]; then
        AUTH_PASSWORD="$(cat .hy2_pass)"
        echo "✅ 读取已有强密码。"
    else
        base=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)
        AUTH_PASSWORD="$(printf "%s" "$base" | openssl dgst -sha256 | awk '{print $2}' | head -c 32)"
        echo "$AUTH_PASSWORD" > .hy2_pass
        chmod 600 .hy2_pass
        echo "🔐 已生成强密码并写入 .hy2_pass"
    fi
}

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
    chmod 600 "$KEY_FILE"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件 ----------
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
bandwidth:
  up: "60mbps"
  down: "60mbps"
quic:
  max_idle_timeout: "30s"
  max_concurrent_streams: 2
  initial_stream_receive_window: 32768
  max_stream_receive_window: 65536
  initial_conn_receive_window: 65536
  max_conn_receive_window: 131072
  keepalive_period: "7s"
EOF
    echo "✅ 写入配置 server.yaml（端口=${SERVER_PORT}, SNI=${SNI}, ALPN=${ALPN}）。"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    IP=$(curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（稳态优化版）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口: $SERVER_PORT"
    echo "   🔑 密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（仅供个人使用）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Private"
    echo ""
    echo "📄 客户端配置文件示例:"
    echo "server: ${IP}:${SERVER_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${SNI}"
    echo "  alpn: [\"${ALPN}\"]"
    echo "  insecure: true"
    echo "socks5:"
    echo "  listen: 127.0.0.1:1080"
    echo "http:"
    echo "  listen: 127.0.0.1:8080"
    echo "=========================================================================="
}

# ---------- 守护进程逻辑 ----------
daemon_run() {
    echo "🛡️ 启动守护模式：后台运行并自动重启"
    while true; do
        nohup "$BIN_PATH" server -c server.yaml >> hy2.log 2>&1 &
        PID=$!
        echo "🚀 Hysteria2 已启动 (PID=$PID)，日志写入 hy2.log"
        wait $PID
        EXIT_CODE=$?
        echo "⚠️ 进程退出 (code=$EXIT_CODE)，5 秒后重启..."
        sleep 5
    done
}

# ---------- 主逻辑 ----------
main() {
    ensure_password
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    daemon_run
}

main "$@"
