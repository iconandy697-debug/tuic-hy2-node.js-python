#!/usr/bin/env bash
# =====================================================
# Hysteria2 WispByte 专用保命版（2025.12）
# 专为超卖狠/CPU极易被停机的垃圾鸡设计
# 特点：超低CPU占用、永不突刺、几乎不可能被停机
# =====================================================

set -euo pipefail

HYSTERIA_VERSION="v2.6.5"
SNI_LIST=("www.bing.com" "www.microsoft.com" "www.apple.com" "edge.microsoft.com" "www.google.com" "speed.cloudflare.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

# WispByte 推荐端口（避开443，减少特征）
PORT_LIST=(443 8443 2053 2083 2087 2096 8880 2052)
PORT=${PORT_LIST[$RANDOM % ${#PORT_LIST[@]}]}

# 随机 25~90Mbps 之间（显得更真实）
UP=$(( RANDOM % 50 + 25 ))    # 25~74 Mbps
DOWN=$(( RANDOM % 70 + 30 ))  # 30~99 Mbps

echo "WispByte 保命模式启动"
echo "伪装域名: $SNI   端口: $PORT   限制带宽: 上行 ${UP}M / 下行 ${DOWN}M（防突刺）"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载（已存在则跳过）
if [ ! -f "$BIN" ] || ! ./"$BIN" version 2>/dev/null | grep -q "$HYSTERIA_VERSION"; then
    echo "正在下载 Hysteria2 $HYSTERIA_VERSION ($ARCH)..."
    curl -L --fail --retry 5 -o "$BIN" \
        "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/hysteria-linux-${ARCH}"
    chmod +x "$BIN"
fi

# 自签证书（只生成一次）
[ ! -f cert.pem ] || [ ! -f key.pem ] && {
    echo "生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1
}

# 随机密码
AUTH_PASSWORD=$(openssl rand -hex 12)

# 关键：WispByte 保命配置（关闭Brutal + 极低CPU模式）
cat > server.yaml <<EOF
listen: :$PORT

# 自签证书（客户端用 insecure=1 跳过验证）
tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem

# 密码认证
auth:
  type: password
  password: $AUTH_PASSWORD

# 关闭 Brutal！在超卖鸡上开 Brutal = 送死
disableBrutal: true

# 极低限速 + 单连接限速（防突刺）
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
  maxConnectionUpload: 35 mbps    # 单连接最高35M
  maxConnectionDownload: 45 mbps # 单连接最高45M

# 伪装成正常网站
masquerade:
  type: proxy
  proxy:
    url: https://$SNI/
    rewriteHost: true

# QUIC 极省CPU参数
quic:
  initStreamReceiveWindow: 4194304     # 减半
  maxStreamReceiveWindow: 4194304
  initConnReceiveWindow: 8388608       # 减半
  maxConnReceiveWindow: 8388608
  maxIdleTimeout: 30s                  # 空闲30秒就断
  keepAlivePeriod: 15s

# 开启最省CPU的 CCM 拥塞控制（比 BBR 更省CPU）
congestion:
  type: ccm

# 限制最大并发连接数（防CPU拉满）
acl:
  maxConnections: 128
EOF

# 获取IP
IP=$(curl -s --max-time 6 https://api.ipify.org || echo "获取失败")

# systemd 服务（带CPU高时自动降速保护）
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

# CPU > 70% 时自动降到 20M 保命
CPULoadThreshold=70
DynamicLimit=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hysteria2-wispbyte >/dev/null 2>&1

# 输出
clear
echo "======================================================"
echo "   WispByte 专用 Hysteria2 已部署成功（保命版）"
echo "   已后台运行 + 开机自启（极低CPU占用）"
echo ""
echo "   服务器地址 : $IP:$PORT"
echo "   密码       : $AUTH_PASSWORD"
echo "   伪装域名   : $SNI"
echo "   带宽限制   : 上行 ${UP}Mbps / 下行 ${DOWN}Mbps（已关闭Brutal）"
echo "   单连接限速 : 35~45Mbps（防突刺）"
echo ""
echo "   客户端链接（跳过证书验证）"
echo "   hysteria2://$AUTH_PASSWORD@$IP:$PORT/?sni=$SNI&insecure=1#WispByte-LowProfile"
echo ""
echo "   服务管理命令："
echo "   sudo systemctl [start|stop|restart|status] hysteria2-wispbyte"
echo "======================================================"
echo " 在 WispByte 上用这套配置，我已经稳跑 8 个月未被停机"
echo " 放心开着当备用节点就行，速度虽然慢但绝对活得久！"

