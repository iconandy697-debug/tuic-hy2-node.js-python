#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 优化部署脚本（带宽可调 + 多 ALPN + IPv4 优先 + Let’s Encrypt fallback + 多 SNI 自动选择）
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
echo "Hysteria2 优化部署脚本（Shell 版，支持多 SNI 自动选择）"
echo "支持命令行端口参数，如：bash new3.sh 443"
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

# ---------- 工具函数：IP 解析 ----------
get_server_ip() {
    # 获取公网 IPv4（若失败给占位值）
    curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

resolve_domain_ipv4s() {
    # 解析域名 A 记录（IPv4），依次尝试 getent / dig / nslookup
    local domain="$1"
    local ips=()

    if command -v getent >/dev/null 2>&1; then
        mapfile -t ips < <(getent ahostsv4 "$domain" | awk '/STREAM/ {print $1}' | sort -u)
    fi
    if [[ ${#ips[@]} -eq 0 && command -v dig >/dev/null 2>&1 ]]; then
        mapfile -t ips < <(dig +short A "$domain" | grep -E '^[0-9.]+$' | sort -u)
    fi
    if [[ ${#ips[@]} -eq 0 && command -v nslookup >/dev/null 2>&1 ]]; then
        mapfile -t ips < <(nslookup -type=A "$domain" 2>/dev/null | awk '/Address: /{print $2}' | grep -E '^[0-9.]+$' | sort -u)
    fi

    printf "%s\n" "${ips[@]}"
}

# ---------- 读取与选择 SNI ----------
read_sni_candidates() {
    local candidates=()

    # 环境变量优先：逗号分隔
    if [[ -n "$SNI_LIST" ]]; then
        IFS=',' read -r -a arr <<< "$SNI_LIST"
        for d in "${arr[@]}"; do
            d="$(echo "$d" | xargs)" # trim
            [[ -n "$d" ]] && candidates+=("$d")
        done
    fi

    # 文件 .sni_list（每行一个域名）
    if [[ -f ".sni_list" ]]; then
        while IFS= read -r line; do
            line="$(echo "$line" | xargs)"
            [[ -n "$line" ]] && candidates+=("$line")
        done < ".sni_list"
    fi

    # 如果都为空，使用单域名 SNI
    if [[ ${#candidates[@]} -eq 0 ]]; then
        candidates+=("$SNI")
    fi

    printf "%s\n" "${candidates[@]}"
}

pick_active_sni() {
    local server_ip="$1"
    shift
    local domains=("$@")

    # 优先选择 A 记录包含本机公网 IPv4 的域名
    for d in "${domains[@]}"; do
        mapfile -t ips < <(resolve_domain_ipv4s "$d")
        for ip in "${ips[@]}"; do
            if [[ "$ip" == "$server_ip" ]]; then
                echo "$d"
                return 0
            fi
        done
    done

    # 如果没有完全匹配的，选择第一个存在 A 记录的域名
    for d in "${domains[@]}"; do
        mapfile -t ips < <(resolve_domain_ipv4s "$d")
        if [[ ${#ips[@]} -gt 0 ]]; then
            echo "$d"
            return 0
        fi
    done

    # 都没有解析，回退到第一个
    echo "${domains[0]}"
    return 0
}

# ---------- 生成/读取强密码 ----------
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

# ---------- 自签证书生成（支持单域名或 SAN） ----------
generate_self_signed_cert() {
    local primary_cn="$1"
    shift
    local san_domains=("$@")

    echo "🔑 使用 openssl 生成自签证书（prime256v1，含 SAN）..."
    mkdir -p "$(dirname "$CERT_FILE")"

    local openssl_cnf
    openssl_cnf="$(mktemp)"
    {
        echo "[req]"
        echo "distinguished_name = req_distinguished_name"
        echo "req_extensions = v3_req"
        echo "prompt = no"
        echo
        echo "[req_distinguished_name]"
        echo "CN = ${primary_cn}"
        echo
        echo "[v3_req]"
        echo "keyUsage = keyEncipherment, dataEncipherment"
        echo "extendedKeyUsage = serverAuth"
        echo -n "subjectAltName = "
        if [[ ${#san_domains[@]} -gt 0 ]]; then
            local idx=1
            for d in "${san_domains[@]}"; do
                echo -n "DNS:${d}"
                [[ $idx -lt ${#san_domains[@]} ]] && echo -n ", "
                ((idx++))
            done
            echo ""
        else
            echo "DNS:${primary_cn}"
        fi
    } > "$openssl_cnf"

    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -config "$openssl_cnf"
    chmod 600 "$KEY_FILE"
    rm -f "$openssl_cnf"
    echo "✅ 自签证书生成成功（客户端需配置 insecure:true）。"
}

# ---------- 申请证书（支持多域名） ----------
ensure_cert() {
    # 读取候选域名并计算可用域名（解析到公网 IP）
    local server_ip="$1"
    shift
    local sni_candidates=("$@")

    local matched_domains=()
    for d in "${sni_candidates[@]}"; do
        mapfile -t ips < <(resolve_domain_ipv4s "$d")
        for ip in "${ips[@]}"; do
            if [[ "$ip" == "$server_ip" ]]; then
                matched_domains+=("$d")
                break
            fi
        done
    done

    # 证书已存在则跳过
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 已存在证书，使用现有 cert/key。"
        return
    fi

    # 尝试使用 certbot 申请多域名证书（如有）
    if [ "$(id -u)" -eq 0 ] && command -v certbot >/dev/null 2>&1 && [[ ${#matched_domains[@]} -gt 0 ]]; then
        echo "🔑 使用 certbot 自动申请 Let’s Encrypt 证书..."
        local args=()
        for d in "${matched_domains[@]}"; do
            args+=("-d" "$d")
        done
        if certbot certonly --standalone "${args[@]}" --agree-tos -m "admin@${matched_domains[0]}" --non-interactive; then
            # 使用第一个域名的 live 目录
            ln -sf "/etc/letsencrypt/live/${matched_domains[0]}/fullchain.pem" "$CERT_FILE"
            ln -sf "/etc/letsencrypt/live/${matched_domains[0]}/privkey.pem" "$KEY_FILE"
            echo "✅ 已申请并配置 Let’s Encrypt 证书（${matched_domains[*]}）。"
            return
        else
            echo "⚠️ certbot 申请失败，回退到自签证书。"
        fi
    else
        echo "⚠️ 无法使用 certbot（非 root 或未安装或无匹配域名），回退到自签证书。"
    fi

    # 自签：使用选中域名为 CN，所有候选域名作为 SAN
    local primary="${sni_candidates[0]}"
    generate_self_signed_cert "$primary" "${sni_candidates[@]}"
}

# ---------- 写配置文件 ----------
write_config() {
    local active_sni="$1"
cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "${CERT_FILE}"
  key: "${KEY_FILE}"
  alpn:
    - "h3"
    - "h2"
    - "http/1.1"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
bandwidth:
  up: "${UP_BW}"
  down: "${DOWN_BW}"
quic:
  max_idle_timeout: "20s"
  max_concurrent_streams: 8
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144
  keepalive_period: "7s"
prefer_ipv4: true
log:
  level: info
  file: "/var/log/hysteria2.log"
EOF
    echo "✅ 写入优化配置 server.yaml（端口=${SERVER_PORT}, SNI=${active_sni}, 带宽=${UP_BW}/${DOWN_BW}）。"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    local ACTIVE_SNI="$2"
    echo "🎉 Hysteria2 部署成功！（多 SNI 自动选择版）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口: $SERVER_PORT"
    echo "   🔑 密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（仅供个人使用）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${ACTIVE_SNI}&alpn=h3&insecure=0#Hy2-Private"
    echo ""
    echo "📄 客户端配置文件示例:"
    echo "server: ${IP}:${SERVER_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${ACTIVE_SNI}"
    echo "  alpn: [\"h3\",\"h2\",\"http/1.1\"]"
    echo "  insecure: false"
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
        nohup "$BIN_PATH" server -c server.yaml >> /var/log/hy2.log 2>&1 &
        PID=$!
        echo "🚀 Hysteria2 已启动 (PID=$PID)，日志写入 /var/log/hy2.log"
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

    # 读取候选域名
    mapfile -t CANDIDATES < <(read_sni_candidates)
    echo "🔎 SNI 候选域名: ${CANDIDATES[*]}"

    # 获取服务器公网 IPv4
    SERVER_IP="$(get_server_ip)"
    echo "🌐 检测到公网 IPv4: $SERVER_IP"

    # 自动选择 ACTIVE_SNI
    ACTIVE_SNI="$(pick_active_sni "$SERVER_IP" "${CANDIDATES[@]}")"
    echo "✅ 选定 SNI: $ACTIVE_SNI"

    # 证书（优先多域名，回退自签）
    ensure_cert "$SERVER_IP" "${CANDIDATES[@]}"

    # 写配置并启动
    write_config "$ACTIVE_SNI"
    print_connection_info "$SERVER_IP" "$ACTIVE_SNI"
    daemon_run
}

main "$@"
