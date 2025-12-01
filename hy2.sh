#!/usr/bin/env bash
# =====================================================
# Hysteria2 WispByte 保命版（改进+自动更新 2025.12）
# =====================================================

set -euo pipefail

# 伪装域名列表（带端口）
SNI_LIST=(
    "https://www.bing.com:443"
    "https://www.microsoft.com:443"
    "https://www.apple.com:443"
    "https://edge.microsoft.com:443"
    "https://www.google.com:443"
    "https://speed.cloudflare.com:443"
)

# 随机选择一个域名+端口
SNI_URL=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}
SNI=$(echo "$SNI_URL" | sed -E 's#https://([^:/]+).*#\1#')
PORT=$(echo "$SNI_URL" | sed -E 's#.*:([0-9]+)$#\1#')

# 随机带宽
UP=$(( RANDOM % 50 + 25 ))    # 25~74 Mbps
DOWN=$(( RANDOM % 70 + 30 ))  # 30~99 Mbps
MAX_UP=$(( UP * 70 / 100 ))   # 单连接最高不超过总带宽的70%
MAX_DOWN=$(( DOWN * 70 / 100 ))

echo "WispByte 保命模式启动"
echo "伪装域名: $SNI   端口: $PORT   限制带宽: 上行 ${UP}M / 下行 ${DOWN}M"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 最简洁可用的下载函数
download_hysteria() {
    local ARCH=$1
    local BIN="hysteria-linux-${ARCH}"

    echo "正在获取最新版本下载链接 ($ARCH)..."
    URL=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
        | grep -o "https.*hysteria-linux-${ARCH}" | head -n1)

    if [ -z "$URL" ]; then
        echo "未找到下载链接，请检查架构: $ARCH"
        exit 1
    fi

    echo "下载地址: $URL"
    curl -L --fail --retry 5 -o "$BIN" "$URL"
    chmod +x "$BIN"
}

# 下载（已存在则跳过）
if [ ! -f "$BIN" ]; then
    download_hysteria "$ARCH"
fi

# 自签证书（只生成一次）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1
fi

# 随机密码（保存到文件）
AUTH_PASSWORD=$(openssl rand -hex 12)
echo "$AUTH_PASSWORD" > password.txt

# 配置文件
cat > server.yaml <<EOF
listen: :$PORT

tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

auth:
  type: password
  password: $AUTH_PASSWORD

disableBrutal: true

bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
  maxConnectionUpload: ${MAX_UP} mbps
  maxConnectionDownload: ${MAX_DOWN} mbps

masquerade:
  type: proxy
  proxy:
    url: https://$SNI/
    rewriteHost: true

quic:
  initStreamReceiveWindow: 4194304
  maxStreamReceiveWindow: 4194304
  initConnReceiveWindow: 8388608
  maxConnReceiveWindow: 8388608
  maxIdleTimeout: 30s
  keepAlivePeriod: 15s

congestion:
  type: ccm

acl:
  maxConnections: 128
EOF

# 获取IP
IP=$(curl -s --max-time 6 https://api.ipify.org || echo "获取失败")

# systemd 服务（合法字段）
sudo tee /etc/systemd/system/hysteria2-wispbyte.service > /dev/null <<EOF
[Unit]
Description=Hysteria2 WispByte 保命版
After=network.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/$BIN server -c $(pwd)/server.yaml
Restart=always
RestartSec=10
LimitNOFILE=65536
CPUQuota=70%

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hysteria2-wispbyte >/dev/null 2>&1

# 自动更新脚本
cat > update-hysteria2.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="hysteria2-wispbyte"

case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
    | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

CURRENT_VERSION=$("./$BIN" version 2>/dev/null || echo "none")

if [[ "$LATEST_VERSION" == "$CURRENT_VERSION" ]]; then
    echo "已经是最新版本，无需更新。"
    exit 0
fi

echo "正在下载 Hysteria2 $LATEST_VERSION ($ARCH)..."
URL=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
    | grep -o "https.*hysteria-linux-${ARCH}" | head -n1)

if [ -z "$URL" ]; then
    echo "下载链接为空，请检查架构或版本"
    exit 1
fi

curl -L --fail --retry 5 -o "$BIN.new" "$URL"
chmod +x "$BIN.new"
mv "$BIN.new" "$BIN"

echo "更新完成，重启服务..."
sudo systemctl restart "$SERVICE_NAME"
EOF

chmod +x update-hysteria2.sh

# 输出
echo "======================================================"
echo "   WispByte 专用 Hysteria2 已部署成功（改进保命版+自动更新）"
echo "   已后台运行 + 开机自启（极低CPU占用）"
echo ""
echo "   服务器地址 : $IP:$PORT"
echo "   密码       : $AUTH_PASSWORD (已保存到 password.txt)"
echo "   伪装域名   : $SNI"
echo "   带宽限制   : 上行 ${UP}Mbps / 下行 ${DOWN}Mbps"
echo "   单连接限速 : ${MAX_UP}Mbps / ${MAX_DOWN}Mbps"
echo ""
echo "   客户端链接（跳过证书验证）"
echo "   hysteria2://$AUTH_PASSWORD@$IP:$PORT/?sni=$SNI&insecure=1#WispByte-LowProfile"
echo ""
echo "   服务管理命令："
echo "   sudo systemctl [start|stop|restart|status] hysteria2-wispbyte"
echo ""
echo "   自动更新脚本： ./update-hysteria2.sh"
echo "   可加入 crontab 定时执行以保持最新版本"
echo "======================================================"
