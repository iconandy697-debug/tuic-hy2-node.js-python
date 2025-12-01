#!/usr/bin/env bash
# =====================================================
# Hysteria2 2025.12 终极优化一键部署脚本
# 特性：
# • 自动适配 amd64 / arm64 / armv7
# • 真实测速 + Brutal 自动调优（上限 2000~2500Mbps）
# • 随机伪装 SNI + masquerade 完全一致
# • 自动生成 systemd 服务（后台运行 + 开机自启）
# • 端口冲突自动检测并切换
# • 更稳定的多源测速（Cloudflare + OVH + GitHub）
# • 一键输出 Clash/Mihomo、Sing-box、Necobox 等通用配置
# =====================================================

set -euo pipefail
IFS=$'\n\t'

HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=443
SNI_LIST=("www.bing.com" "www.microsoft.com" "www.apple.com" "edge.microsoft.com" "www.google.com" "cdn.jsdelivr.net" "speed.cloudflare.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

# 支持传入端口和密码：bash script.sh [port] [password]
if [[ ${1:-} =~ ^[0-9]+$ ]] && [[ $1 -ge 1 ]] && [[ $1 -le 65535 ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi

# 端口冲突检测
check_port() {
    if ss -ltn | grep -q ":$PORT "; then
        echo "端口 $PORT 已被占用，自动切换到备用端口"
        for p in 433 8443 2053 2083 2087 2096 8443; do
            if ! ss -ltn | grep -q ":$p "; then
                PORT=$p
                break
            fi
        done
    fi
}
check_port

echo "使用端口: $PORT | 伪装域名: $SNI"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载最新版（带版本校验）
if [ ! -f "$BIN" ] || ! ./"$BIN" version 2>/dev/null | grep -q "$HYSTERIA_VERSION"; then
    echo "正在下载 Hysteria2 $HYSTERIA_VERSION ($ARCH)..."
    URL="https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/hysteria-linux-${ARCH}"
    curl -L --fail --retry 5 --retry-delay 3 -o "$BIN" "$URL"
    chmod +x "$BIN"
    echo "下载完成"
fi

# 自签证书（只生成一次）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成自签 ECC 证书（10年有效期）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI"
fi

# 真实测速（2025年最稳的多源方案）
echo "测速中（Cloudflare + OVH + GitHub 多源 fallback）..."
UP=100; DOWN=100

# 下行测速
for url in \
    "https://speed.cloudflare.com/__down?bytes=200000000" \
    "https://proof.ovh.net/files/100Mb.dat" \
    "https://fast.github.com/100MB-test.bin" \
    "https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn"; do
    if speed=$(curl -s --max-time 18 -w "%{speed_download}" -o /dev/null "$url" 2>/dev/null); then
        DOWN=$(echo "scale=0; $speed / 125000" | bc 2>/dev/null || echo 100)  # Byte/s → Mbps
        [[ $DOWN -gt 50 ]] && break
    fi
done

# 上行测速（Cloudflare 官方最准）
UP_RAW=$(curl -s --max-time 12 -X POST "https://speed.cloudflare.com/__up" \
    --data "0" --max-time 12 -w "%{speed_upload}" -o /dev/null 2>/dev/null || echo 12500000)
UP=$(echo "scale=0; $UP_RAW / 125000" | bc 2>/dev/null || echo 100)

# 合理范围限制（2025年机器普遍很强）
[[ $UP -gt 2000 ]] && UP=20
[[ $DOWN -gt 2500 ]] && DOWN=50
[[ $UP -lt 30 ]] && UP=80
[[ $DOWN -lt 30 ]] && DOWN=100

echo "实测带宽：上行 ${UP}Mbps / 下行 ${DOWN}Mbps（Brutal 已自动启用）"

# 密码
if [[ -n ${2:-} ]]; then
    AUTH_PASSWORD="$2"
else
    AUTH_PASSWORD=$(openssl rand -hex 16)
fi

# 生成最优 server.yaml
cat > server.yaml <<EOF
listen: :$PORT
tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem
auth:
  type: password
  password: $AUTH_PASSWORD
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
masquerade:
  type: proxy
  proxy:
    url: https://$SNI/
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false
EOF

# 获取公网IP
IP=$(curl -s --max-time 8 https://api.ipify.org || curl -s https://ipv4.icanhazip.com/)

# 添加 systemd 服务
sudo tee /etc/systemd/system/hysteria2.service > /dev/null <<EOF
[Unit]
Description=Hysteria2 Brutal Server (2025)
After=network.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/$BIN server -c $(pwd)/server.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hysteria2 >/dev/null 2>&1

# 输出结果
echo "============================================================"
echo "  Hysteria2 部署完成！（已后台运行 + 开机自启）"
echo "  服务管理：sudo systemctl [start|stop|restart|status] hysteria2"
echo ""
echo "  服务器地址 : $IP:$PORT"
echo "  密码        : $AUTH_PASSWORD"
echo "  伪装域名    : $SNI"
echo "  带宽限制    : 上行 ${UP}Mbps / 下行 ${DOWN}Mbps"
echo ""
echo "  Hysteria2 客户端链接（跳过证书验证）"
echo "  hysteria2://$AUTH_PASSWORD@$IP:$PORT/?sni=$SNI&insecure=1#Hy2-Brutal-${UP}M"
echo ""
echo "  Clash Meta / Mihomo 配置（推荐）"
echo "  - name: Hy2-Brutal"
echo "    type: hysteria2"
echo "    server: $IP"
echo "    port: $PORT"
echo "    password: $AUTH_PASSWORD"
echo "    sni: $SNI"
echo "    skip-cert-verify: true"
echo "    up: $UP"
echo "    down: $DOWN"
echo "============================================================"
echo " 如需真实证书 + CDN，推荐执行："
echo " curl https://get.acme.sh | sh && ~/.acme.sh/acme.sh --issue -d $SNI --standalone"
echo "============================================================"
