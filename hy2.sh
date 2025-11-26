#!/usr/bin/env bash
# Hysteria2 终极低内存优化版（WispByte 64MB 专属）
# 密码自动生成 + salad 混淆 + 动态伪装 + 极致性能

set -e

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
    echo "正在下载 Hysteria2 ${HYSTERIA_VERSION} (${ARCH}) ..."
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN}"
    curl -L --fail --retry 5 --retry-delay 3 -o "$BIN" "$URL" || \
        wget -O "$BIN" "$URL"
    chmod +x "$BIN"
fi

# 生成自签证书（使用更强的 P-384 曲线，兼容性依然很好）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
    echo "生成高强度自签证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -days 3650 \
        -nodes -keyout key.pem -out cert.pem -subj "/CN=${SNI}" \
        -addext "subjectAltName = DNS:${SNI}"
fi

# 写入最优配置（已针对 64MB 内存 + 高隐蔽性 + 高性能调优）
cat > server.yaml <<EOF
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
  password: "${AUTH_PASSWORD}"

masquerade:
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

quic:
  initStreamReceiveWindow: 8388608      # 8MB
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520       # 20MB
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

fastOpen: true
lazy: true
EOF

# 获取公网IP
IP=$(curl -s4 ifconfig.co || curl -s4 ipinfo.io/ip || echo "YOUR_IP")

echo "===================================================="
echo "       Hysteria2 部署完成！（WispByte 优化版）"
echo "===================================================="
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
