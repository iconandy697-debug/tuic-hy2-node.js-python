#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极致优化部署脚本（2025最新版，低内存友好 + 伪装 + systemd）
set -euo pipefail

HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="wispbyte.iconandy.dpdns.org"   # 可改成你自己的常用域名

# 默认带宽（可通过环境变量覆盖，例如：UP=100 DOWN=200 bash new2.sh 443）
UP_BW="${UP:-50mbps}"
DOWN_BW="${DOWN:-100mbps}"

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "   Hysteria2 极致优化一键脚本（低内存 + 伪装 + systemd）"
echo "   使用示例：bash $0 443      或    UP=100 DOWN=200 bash $0 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ========== 参数处理 ==========
if [[ $# -ge 1 ]] && [[ -n "$1" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 使用默认端口: $SERVER_PORT"
fi

# ========== 架构检测 ==========
case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    *) echo "❌ 不支持的架构: $(uname -m)"; exit 1 ;;
esac
BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="/usr/local/bin/hysteria"

# ========== 防止重复运行 ==========
if pidof -x "$(basename $BIN_PATH)" > /dev/null; then
    echo "⚠️  Hysteria2 正在运行中，阻止重复启动"
    exit 1
fi

# ========== 强密码 ==========
if [[ -f ".hy2_pass" ]] && [[ -s ".hy2_pass" ]]; then
    AUTH_PASSWORD="$(cat .hy2_pass)"
    echo "✅ 读取已有密码"
else
    AUTH_PASSWORD="$(openssl rand -hex 16)"
    echo "$AUTH_PASSWORD" > .hy2_pass
    chmod 600 .hy2_pass
    echo "🔐 新生成 32 位十六进制强密码并保存至 .hy2_pass"
fi

# ========== 下载最新二进制 ==========
if [[ ! -f "$BIN_PATH" ]] || [[ "$($BIN_PATH version | head -n1 | awk '{print $3}')" != "$HYSTERIA_VERSION" ]]; then
    echo "⏳ 下载/更新 Hysteria2 $HYSTERIA_VERSION ($ARCH) ..."
    curl -L -o "$BIN_PATH" "https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    chmod +x "$BIN_PATH"
    echo "✅ 二进制更新完成"
else
    echo "✅ 二进制已是最新的 $HYSTERIA_VERSION"
fi

# ========== 自签证书 ==========
if [[ ! -f "$CERT_FILE" ]] || [[ ! -f "$KEY_FILE" ]]; then
    echo "🔑 生成自签 ECC 证书（3650 天）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$SNI"
    chmod 600 "$KEY_FILE"
    echo "✅ 证书生成成功"
else
    echo "✅ 使用现有证书"
fi

# ========== 写入优化配置 ==========
cat > /etc/hysteria2.yaml <<EOF
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
  disablePathMTUDiscovery: false   # 2025 建议开启，部分网络关闭会更慢
  maxConcurrentStreams: 16         # 低内存最佳值

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

# 强制走 IPv4
disableIPv6: true
EOF

echo "✅ 配置已写入 /etc/hysteria2.yaml（带宽 ${UP_BW}/${DOWN_BW}，端口 $SERVER_PORT）"

# ========== systemd 服务 ==========
cat > /etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$BIN_PATH server -c /etc/hysteria2.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576
# 日志轮转（防止爆盘）
StandardOutput=append:/var/log/hysteria2.log
StandardError=append:/var/log/hysteria2.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria2.service > /dev/null 2>&1
sleep 2

if systemctl is-active --quiet hysteria2; then
    echo "🚀 Hysteria2 已通过 systemd 启动成功"
else
    echo "❌ 启动失败，请查看日志：journalctl -u hysteria2 -f"
    exit 1
fi

# ========== 日志自动清理（关键！）==========
cat > /etc/logrotate.d/hysteria2 <<EOF
/var/log/hysteria2.log {
    daily
    rotate 3
    compress
    missingok
    notifempty
    size 10M
    copytruncate
}
EOF

# ========== 输出连接信息 ==========
IP=$(curl -s https://api.ipify.org || echo "YOUR_IP")

echo "============================================================"
echo "🎉 Hysteria2 部署完成！（极致优化版）"
echo "   IP      : $IP"
echo "   端口    : $SERVER_PORT"
echo "   密码    : $AUTH_PASSWORD"
echo "   SNI     : $SNI"
echo "   ALPN    : h3,h2,http/1.1"
echo "   跳检    : 是（insecure=1）"
echo ""
echo "🔗 节点链接（Clash Meta / Nekobox / Sing-box 通用）:"
echo "hysteria2://$AUTH_PASSWORD@$IP:$SERVER_PORT/?sni=$SNI&alpn=h3,h2,http/1.1&insecure=1#Hy2-$(hostname)"
echo ""
echo "⚙️ 日志查看：journalctl -u hysteria2 -f"
echo "⚙️ 重启服务：systemctl restart hysteria2"
echo "============================================================"

exit 0
