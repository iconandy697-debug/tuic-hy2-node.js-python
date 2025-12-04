#!/usr/bin/env bash
# Hysteria2 Wispbyte Pterodactyl Docker 专用版（2025亲测100%成功）
# 直接复制全部内容粘贴到面板控制台回车即可
set -e

# ========== 可自定义参数（直接改下面这几行）==========
SERVER_PORT=443                  # 改成你面板里开放的端口（一般 443 或 22222）
UP_BW="100 mbps"                 # 上行带宽
DOWN_BW="300 mbps"               # 下行带宽
SNI="wispbyte.iconandy.dpdns.org"   # 随便填个常用域名就行

# ========== 自动获取公网IP ==========
IP=$(curl -s https://api.ipify.org || echo "1.1.1.1")

# ========== 生成强密码 ==========
if [[ -f .hy2_pass ]]; then
    PASS=$(cat .hy2_pass)
else
    PASS=$(openssl rand -hex 16)
    echo $PASS > .hy2_pass
fi

# ========== 下载二进制到当前目录（只读文件系统绕过方案）==========
echo "正在下载 Hysteria2（arm64/am64自动识别）..."
ARCH=$(uname -m)
if [[ "$ARCH" == *"arm"* ]] || [[ "$ARCH" == *"aarch64"* ]]; then
    ARCH="arm64"
else
    ARCH="amd64"
fi

curl -L -o hy2 "https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-$ARCH"
chmod +x hy2

# ========== 生成自签证书 ==========
if [[ ! -f cert.pem ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout key.pem -out cert.pem -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1
fi

# ========== 写入最优配置 ==========
cat > config.yaml <<EOF
listen: :$SERVER_PORT

tls:
  cert: cert.pem
  key: key.pem

auth:
  type: password
  password: $PASS

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
  maxConcurrentStreams: 32

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

disableIPv6: true
EOF

# ========== 清理旧日志（防止爆盘）==========
echo "" > hy2.log

# ========== 启动（前台运行，面板会自动重启）==========
echo "========================================================"
echo " Hysteria2 启动成功！（Wispbyte Docker专用版）"
echo " IP: $IP:$SERVER_PORT"
echo " 密码: $PASS"
echo " SNI: $SNI"
echo " 带宽: ↑$UP_BW ↓$DOWN_BW"
echo ""
echo " 节点链接（直接导入 Clash/Nekobox/Sing-box）:"
echo "hysteria2://$PASS@$IP:$SERVER_PORT/?sni=$SNI&alpn=h3,h2,http/1.1&insecure=1#Wispbyte-Hy2"
echo "========================================================"
echo "日志实时查看：tail -f hy2.log"
echo "如需重启直接在面板点 Restart 即可"
echo "========================================================"

# 这行最关键：前台运行，面板才能检测进程活着
exec ./hy2 server -c config.yaml 2>&1 | tee -a hy2.log
