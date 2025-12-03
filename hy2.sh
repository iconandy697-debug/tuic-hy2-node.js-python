#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 精简部署脚本（多 SNI 自动选择 + 自签证书）
# 适用于低内存环境，支持参数化配置

set -euo pipefail

# ---------- 基础配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
CERT_FILE="/etc/hysteria2/cert.pem"
KEY_FILE="/etc/hysteria2/key.pem"
SNI_LIST="www.bing.com,cloudflare.com,apple.com"

UP_BW="${UP_BW:-200mbps}"
DOWN_BW="${DOWN_BW:-200mbps}"

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 精简部署脚本（Shell 版，支持多 SNI 自动选择，自签证书）"
echo "支持命令行端口参数，如：bash hy2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
if [ $# -ge 1 ] && [ -n "$1" ]; then
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
    case "$machine" in
        *arm64*|*aarch64*) echo "arm64" ;;
        *x86_64*|*amd64*) echo "amd64" ;;
        *) echo "" ;;
    esac
}
ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 工具函数 ----------
get_server_ip() {
    curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

resolve_domain_ipv4s() {
    local domain="$1"
    local ips=()
    if command -v getent >/dev/null 2>&1; then
        mapfile -t ips < <(getent ahostsv4 "$domain" | awk '/STREAM/ {print $1}' | sort -u)
    elif command -v dig >/dev/null 2>&1; then
        mapfile -t ips < <(dig +short A "$domain" | grep -E '^[0-9.]+$' | sort -u)
    elif command -v nslookup >/dev/null 2>&1; then
        mapfile -t ips < <(nslookup -type=A "$domain" 2>/dev/null | awk '/Address: /{print $2}' | grep -E '^[0-9.]+$' | sort -u)
    fi
    printf "%s\n" "${ips[@]}"
}

# ---------- 读取与选择 SNI ----------
read_sni_candidates() {
    local candidates=()
    IFS=',' read -r -a arr <<< "$SNI_LIST"
    for d in "${arr[@]}"; do
        d="$(echo "$d" | xargs)"
        [[ -n "$d" ]] && candidates+=("$d")
    done
    printf "%s\n" "${candidates[@]}"
}

pick_active_sni() {
    local server_ip="$1"; shift
    local domains=("$@")
    for d in "${domains[@]}"; do
        mapfile -t ips < <(resolve_domain_ipv4s "$d")
        for ip in "${ips[@]}"; do
            [[ "$ip" == "$server_ip" ]] && echo "$d" && return 0
        done
    done
    echo "${domains[0]}"
}

# ---------- 强密码 ----------
ensure_password() {
    if [[ -f ".hy2_pass" && -s ".hy2_pass" ]]; then
        AUTH_PASSWORD="$(cat .hy2_pass)"
        echo "✅ 读取已有强密码。"
    else
        AUTH_PASSWORD="$(openssl rand -hex 32 | head -c 32)"
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

# ---------- 自签证书 ----------
generate_self_signed_cert() {
    local primary_cn="$1"; shift
    local san_domains=("$@")
    mkdir -p "$(dirname "$CERT_FILE")"
    local openssl_cnf="$(mktemp)"
    {
        echo "[req]"
        echo "distinguished_name=req_distinguished_name"
        echo "req_extensions=v3_req"
        echo "prompt=no"
        echo "[req_distinguished_name]"
        echo "CN=${primary_cn}"
        echo "[v3_req]"
        echo "subjectAltName="
        local idx=1
        for d in "${san_domains[@]}"; do
            echo -n "DNS:${d}"
            [[ $idx -lt ${#san_domains[@]} ]] && echo -n ","
            ((idx++))
        done
        echo ""
    } > "$openssl_cnf"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -config "$openssl_cnf"
    chmod 600 "$KEY_FILE"
    rm -f "$openssl_cnf"
    echo "✅ 自签证书生成成功（客户端需配置 insecure:true）。"
}

ensure_cert() {
    local sni_candidates=("$@")
    local primary="${sni_candidates[0]}"
    generate_self_signed_cert "$primary" "${sni_candidates[@]}"
}

# ---------- 写配置 ----------
write_config() {
    local active_sni="$1"
cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "${CERT_FILE}"
  key: "${KEY_FILE}"
  alpn: ["h3","h2","http/1.1"]
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
bandwidth:
  up: "${UP_BW}"
  down: "${DOWN_BW}"
quic:
  max_idle_timeout: "20s"
  max_concurrent_streams: 8
  keepalive_period: "7s"
prefer_ipv4: true
log:
  level: info
  file: "/var/log/hysteria2.log"
EOF
    echo "✅ 写入配置 server.yaml（端口=${SERVER_PORT}, SNI=${active_sni}）。"
}

# ---------- 打印信息 ----------
print_connection_info() {
    local IP="$1"; local ACTIVE_SNI="$2"
    echo "🎉 Hysteria2 部署成功！（精简版，自签证书）"
    echo "=========================================================================="
    echo "🌐 IP地址: $IP"
    echo "🔌 端口: $SERVER_PORT"
    echo "🔑 密码: $AUTH_PASSWORD"
    echo ""
    echo "节点链接:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${ACTIVE_SNI}&alpn=h3&insecure=1#Hy2-Private"
    echo ""
    echo "客户端配置示例:"
    echo "server: ${IP}:${SERVER_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${ACTIVE_SNI}"
    echo "  alpn: [\"h3\",\"h2\",\"http/1.1\"]"
    echo "  insecure: true"
    echo "=========================================================================="
}

# ---------- 守护进程 ----------
daemon_run() {
    mkdir -p /var/log
    echo "🛡️ 启动守护模式：后台运行并自动重启"
    while true; do
        nohup "$BIN_PATH" server -c server.yaml >> /var/log/hy2.log 2>&1 &
        PID=$!
        echo "🚀 Hysteria2 已启动 (PID=$PID)"
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
    mapfile -
