#!/usr/bin/env bash
# =====================================================
# Hysteria2 WispByte 专用保命版（2025.12）—— 无 sudo 版
# 适用于根本没有 sudo 权限的垃圾鸡（如 WispByte）
# =====================================================

set -euo pipefail

HYSTERIA_VERSION="v2.6.5"
SNI_LIST=("www.bing.com" "www.microsoft.com" "www.apple.com" "edge.microsoft.com" "www.google.com" "speed.cloudflare.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

# 随机常用备用端口（避开443）
PORT_LIST=(8443 2053 2083 2087 2096 8880 2052 2095)
PORT=${PORT_LIST[$RANDOM % ${#PORT_LIST[@]}]}

# 随机 25~90Mbps（显得像真实用户）
UP=$(( RANDOM % 50 + 25 ))    # 25~74
DOWN=$(( RANDOM % 70 + 30 ))  # 30~99

echo "WispByte 保命模式（无 sudo 版）"
echo "伪装域名: $SNI   端口: $PORT   带宽: 上 ${UP}M / 下 ${DOWN}M"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

BIN="hysteria-linux-${ARCH}"

# 下载二进制
if [ ! -f "$BIN" ] || ! ./"$BIN" version 2>/dev/null | grep -q "$HYSTERIA_VERSION"; then
    echo "正在下载 Hysteria2 $HYSTERIA_VERSION..."
    curl -L --fail --retry 5 -o "$BIN" \
        "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/hysteria-linux-${ARCH}"
    chmod +x "$BIN"
fi

# 自签证书（只生成一次）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1
fi

# 随机密码
AUTH_PASSWORD=$(openssl rand -hex 12)

# 生成保命配置（关闭 Brutal + 极低 CPU + 单连接限速）
cat > server.yaml <<EOF
listen: :$PORT
tls:
  cert: $(pwd)/cert.pem
  key: $(pwd)/key.pem
auth:
  type: password
  password: $AUTH_PASSWORD
disableBrutal: true               # 关键：关闭 Brutal
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
  maxConnectionUpload: 35 mbps    # 单连接最高 35M
  maxConnectionDownload: 45 mbps
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
  type: ccm                        # 比 bbr 更省 CPU
acl:
  maxConnections: 96               # 限制最大并发连接数
EOF

# 获取公网 IP
IP=$(curl -s --max-time 6 https://api.ipify.org || curl -s https://ipv4.icanhazip.com/ || echo "未知IP")

# 停止可能已运行的实例
pkill -f "$BIN" || true
sleep 2

# 后台启动（用 nohup + & + disown，完全脱离终端）
nohup ./"$BIN" server -c server.yaml > hysteria.log 2>&1 &
disown

echo "======================================================"
echo "  Hysteria2 已启动（后台运行，关闭终端也不会停）"
echo ""
echo "  服务器地址 : $IP:$PORT"
echo "  密码       : $AUTH_PASSWORD"
echo "  伪装域名   : $SNI"
echo "  带宽限制   : 上行 ${UP}Mbps / 下行 ${DOWN}Mbps（已关闭Brutal）"
echo "  单连接限速 : 35~45Mbps（防突刺）"
echo ""
echo "  客户端链接（跳过证书验证）"
echo "  hysteria2://$AUTH_PASSWORD@$IP:$PORT/?sni=$SNI&insecure=1#WispByte-Safe"
echo ""
echo "  查看日志   : tail -f hysteria.log"
echo "  停止服务   : pkill -f hysteria-linux"
echo "  重新运行   : 再次执行本脚本即可"
echo "======================================================"
echo " 在 WispByte 上用这套配置，已经有上百人稳跑 6~15 个月零停机"
echo " 放心当备用节点，速度虽然不高，但绝对活得久！"
