#!/usr/bin/env bash
# WispByte 专用 Hysteria2 超稳低占用版（2025.12 更新）
# 特点：35M 极限稳速 + 超低 CPU + 自动强密码 + 垃圾网络极稳 + 仅个人用
set -e

# ==================== 可自定义区 ====================
DEFAULT_PORT=$(shuf -i 30000-60000 -n 1)  # 每次部署随机高位端口
SNI="www.bing.com"                        # 改成 www.google.com 也行
ALPN="h3"
MAX_SPEED="35 mbps"                       # WispByte 最高安全速度，勿调高！
# ===================================================

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[1;33m"; NC="\033[0m"
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }

# 自动生成32位超强密码
AUTH_PASSWORD=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)

# 端口支持手动指定，否则随机
if [[ -n "$1" && "$1" =~ ^[0-9]+$ ]]; then
    SERVER_PORT="$1"
    log "使用指定端口: $SERVER_PORT"
else
    SERVER_PORT="$DEFAULT_PORT"
    log "使用随机高位端口: $SERVER_PORT（更隐蔽）"
fi

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构$(uname -m)${NC}"; exit 1 ;;
esac

BIN="hysteria-linux-$ARCH"
INSTALL_PATH="/usr/local/bin/hysteria2"

# 下载最新稳定二进制
if [ ! -f "$INSTALL_PATH" ] || ! "$INSTALL_PATH" version 2>/dev/null | grep -q "v2.6"; then
    log "正在下载 Hysteria2 极简低占用版..."
    curl -L -o /tmp/hy2 "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/$BIN"
    chmod +x /tmp/hy2
    mv -f /tmp/hy2 "$INSTALL_PATH" 2>/dev/null || cp /tmp/hy2 "$HOME/hysteria2"
    HY_PATH=$(which hysteria2 || echo "$HOME/hysteria2")
else
    HY_PATH="$INSTALL_PATH"
fi

# 生成自签证书（放家目录，权限最小）
mkdir -p "$HOME/.hy2"
if [ ! -f "$HOME/.hy2/cert.pem" ]; then
    log "生成自签证书（10年有效）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$HOME/.hy2/key.pem" -out "$HOME/.hy2/cert.pem" \
        -subj "/CN=$SNI" -days 3650 >/dev/null 2>&1
    chmod 600 "$HOME/.hy2/key.pem"
fi

# 写入极致省 CPU + 垃圾网络最稳配置
cat > "$HOME/hy2-config.yaml" <<EOF
listen: :$SERVER_PORT

tls:
  cert: $HOME/.hy2/cert.pem
  key: $HOME/.hy2/key.pem

auth:
  type: password
  password: $AUTH_PASSWORD

bandwidth:
  up: $MAX_SPEED
  down: $MAX_SPEED

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 2097152      # 大幅降低 CPU
  maxStreamReceiveWindow: 2097152
  initConnReceiveWindow: 5242880
  maxConnReceiveWindow: 5242880
  maxIdleTimeout: 30s
  congestionControl: bbr               # 垃圾网络最稳算法

fastOpen: false                        # 关闭 fast-open 降低 CPU
disableMTUDiscovery: true              # 防止某些垃圾网络 MTU 探测卡死

log:
  level: warn                           # 关闭 debug 日志，省 CPU
EOF

# 创建 systemd 服务（后台 + 自动重启）
cat > /tmp/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Personal Node (WispByte UltraStable)
After=network.target

[Service]
Type=simple
ExecStart=$HY_PATH server -c $HOME/hy2-config.yaml
Restart=always
RestartSec=2
LimitNOFILE=4096
Environment="HYPHEN_INSENSITIVE=1"

[Install]
WantedBy=multi-user.target
EOF

# 尝试用 root 安装服务，没 root 就用用户级（WispByte 通常有 sudo）
if command -v sudo >/dev/null 2>&1; then
    sudo cp /tmp/hysteria2.service /etc/systemd/system/hysteria2.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now hysteria2 >/dev/null 2>&1 && SERVICE_OK=1
else
    mkdir -p ~/.config/systemd/user
    cp /tmp/hysteria2.service ~/.config/systemd/user/hysteria2.service
    systemctl --user daemon-reload
    systemctl --user enable --now hysteria2 >/dev/null 2>&1 && SERVICE_OK=1
fi

# 获取公网 IP
IP=$(curl -s4 --max-time 10 ifconfig.co || curl -s6 --max-time 10 ifconfig.co || echo "YOUR_IP")

# 最终输出
clear
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}      WispByte Hysteria2 部署成功！（个人专用）      ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo
echo -e " ${YELLOW}服务器信息${NC}"
echo -e "   IP     : $IP"
echo -e "   端口   : $SERVER_PORT (UDP)"
echo -e "   密码   : $AUTH_PASSWORD"
echo -e "   SNI    : $SNI"
echo
echo -e " ${YELLOW}推荐节点链接（直接导入 Clash/NekoBox/Sing-box）${NC}"
echo -e " hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#WispByte-Hy2-${SERVER_PORT}"
echo
echo -e " ${YELLOW}管理命令${NC}"
echo -e "   重启   : systemctl restart hysteria2    （或 systemctl --user restart hysteria2）"
echo -e "   查看日志: journalctl -f -u hysteria2     （或 journalctl --user -f -u hysteria2）"
echo
echo -e "${GREEN}已全局限速 35Mbps + 超低CPU占用 + BBR抗丢包，长期稳跑无压力！${NC}"
echo

# 启动
if [ "$SERVICE_OK" = "1" ]; then
    sleep 3
    if systemctl is-active --quiet hysteria2 2>/dev/null || systemctl --user is-active --quiet hysteria2; then
        echo -e "${GREEN}Hysteria2 正在运行，可长期自用！${NC}"
    fi
fi
