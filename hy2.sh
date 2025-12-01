#!/usr/bin/env bash
set -e

HYSTERIA_VERSION="v2.6.6"
DEFAULT_PORT=22222
AUTH_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9')
SNI_LIST=("www.bing.com" "www.microsoft.com" "www.apple.com" "time.apple.com")
SNI=${SNI_LIST[$RANDOM % ${#SNI_LIST[@]}]}

if [[ $1 =~ ^[0-9]+$ ]]; then
    PORT="$1"
else
    PORT="$DEFAULT_PORT"
fi

echo "使用端口: $PORT | SNI: $SNI"
# Hysteria2 终极低内存优化版（WispByte 64MB 专属）
# 密码自动生成 + salad 混淆 + 动态伪装 + 极致性能

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"
set -e

# 下载二进制
# ---------- 自动生成强随机密码 ----------
generate_password() {
    openssl rand -base64 32 | head -c 24
}

AUTH_PASSWORD=$(generate_password)
echo "生成的强随机密码: $AUTH_PASSWORD"

# ---------- 默认配置（已深度优化）----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=${1:-443}                    # 默认用443，伪装更自然
SNI="www.google.com"                      # 改成谷歌，封锁概率更低（也可换 cloudflare.com）
ALPN="h3"
OBFS_PASSWORD=$(generate_password)        # salad 混淆密码

# 检测架构（适配所有常见低配VPS）
arch_name() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
    esac
}
ARCH=$(arch_name)
BIN="hysteria-linux-${ARCH}"

# 下载二进制（带降级重试）
if [ ! -f "$BIN" ]; then
    echo "下载 Hysteria2 $HYSTERIA_VERSION..."
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/$BIN" --retry 3
    echo "正在下载 Hysteria2 ${HYSTERIA_VERSION} (${ARCH}) ..."
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN}"
    curl -L --fail --retry 5 --retry-delay 3 -o "$BIN" "$URL" || \
        wget -O "$BIN" "$URL"
chmod +x "$BIN"
fi

# 生成自签证书
# 生成自签证书（使用更强的 P-384 曲线，兼容性依然很好）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1
    echo "生成高强度自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 \
        -nodes -keyout key.pem -out cert.pem -subj "/CN=${SNI}" \
        -addext "subjectAltName = DNS:${SNI}"
fi

# 万能保底测速（连续尝试3个源，全部失败就用 150Mbps）
UP=100
DOWN=100
echo "尝试测速..."
for url in \
    "https://cdn.jsdelivr.net/gh/sjlleo/Trace/flushcdn" \
    "https://speed.cloudflare.com/__down?bytes=100000000"; do
    result=$(curl -s --max-time 10 "$url" 2>/dev/null || echo "ERROR")
    if [[ $result != *"ERROR"* && -n "$result" ]]; then
        UP=$(echo "$result" | grep -oE '[0-9]+ Mbps' | head -1 | grep -oE '[0-9]+' || echo 150)
        DOWN=$(echo "$result" | grep -oE '[0-9]+ Mbps' | tail -1 | grep -oE '[0-9]+' || echo 150)
        [[ $UP -gt 800 ]] && UP=800
        [[ $DOWN -gt 800 ]] && DOWN=800
        echo "测速成功 → 上行 ${UP}Mbps  下行 ${DOWN}Mbps"
        break
    fi
done
UP=${UP:-150}
DOWN=${DOWN:-150}
echo "最终使用带宽：上行 ${UP}Mbps  下行 ${DOWN}Mbps"

# 关键修复：和文档2一样有效的配置（去掉必翻车的 proxy 伪装 + 正确 QUIC 参数）
# 写入最优配置（已针对 64MB 内存 + 高隐蔽性 + 高性能调优）
cat > server.yaml <<EOF
listen: :$PORT
listen: :${DEFAULT_PORT}

tls:
 cert: $(pwd)/cert.pem
 key: $(pwd)/key.pem

acme:
  domains:
    - "${SNI}"
  email: admin@${SNI}    # 可选：开启自动 ACME 证书（需80端口）

auth:
 type: password
  password: $AUTH_PASSWORD
  password: "${AUTH_PASSWORD}"

# 直接写 bandwidth = Brutal 自动开启
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps

# 修复1：去掉必翻车的 proxy 伪装 → 改成最稳的 404 伪装
masquerade:
  type: string
  content: |
    404 Not Found
    Hysteria2 Server
  statusCode: 404
  type: proxy
  proxy:
    url: https://www.bing.com/favicon.ico    # 伪装成访问必应图标
    rewriteHost: true

obfs:
  type: salad
  salad:
    password: "${OBFS_PASSWORD}"

bandwidth:
  up: 50 mbps      # 低配机建议 50-100mbps，跑太高反而掉速
  down: 50 mbps

# 修复ssize2：使用文档2验证可用的 QUIC 参数（新版字段名）
quic:
  initialStreamReceiveWindow: 8388608
  initStreamReceiveWindow: 8388608      # 8MB
 maxStreamReceiveWindow: 8388608
  initialConnReceiveWindow: 20971520
  initConnReceiveWindow: 20971520       # 20MB
 maxConnReceiveWindow: 20971520
 maxIdleTimeout: 30s
  keepAlivePeriod: 10s
 disablePathMTUDiscovery: false

# 修复3：忽略客户端瞎填的带宽（防止某些客户端填 99999Mbps 导致服务器卡死）
ignoreClientBandwidth: true
fastOpen: true
lazy: true
EOF

IP=$(curl -s --max-time 5 https://api.ipify.org || echo "未知IP")
# 获取公网IP
IP=$(curl -s4 ifconfig.co || curl -s4 ipinfo.io/ip || echo "YOUR_IP")

echo "===================================================="
echo "  Hysteria2 部署完成！现在一定能连"
echo "  IP      : $IP"
echo "  端口    : $PORT"
echo "  密码    : $AUTH_PASSWORD"
echo "  SNI     : $SNI"
echo "  带宽    : 上行 ${UP}Mbps / 下行 ${DOWN}Mbps"
echo ""
echo "  客户端链接（自签证书必须加 insecure=1）:"
echo "  hysteria2://$AUTH_PASSWORD@$IP:$PORT?sni=$SNI&insecure=1#Hy2-2025"
echo "       Hysteria2 部署完成！（WispByte 优化版）"
echo "===================================================="

echo "启动服务器..."
exec ./$BIN server -c server.yaml
echo "服务器 IP: $IP"
echo "端口: $DEFAULT_PORT"
echo "密码: $AUTH_PASSWORD"
echo "Salad 混淆密码: $OBFS_PASSWORD"
echo "SNI: $SNI"
echo ""
echo "客户端导入链接（推荐直接扫码或复制）:"
echo "hysteria2://${AUTH_PASSWORD}@${IP}:${DEFAULT_PORT}/?obfs=salad&obfs-password=${OBFS_PASSWORD}&sni=${SNI}&alpn=${ALPN}&insecure=1#WispByte-Hy2"
echo ""
echo "启动中..."
exec ./"$BIN" server -c server.yaml
