#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');
const { execSync, spawn } = require('child_process');
const os = require('os');

// 默认配置（静默）
const HYSTERIA_VERSION = 'v2.6.5';
const DEFAULT_PORT = Math.floor(Math.random() * (65535 - 1024 + 1)) + 1024; // 随机端口
const CERT_FILE = 'cert.pem';
const KEY_FILE = 'key.pem';
const SNI = 'www.microsoft.com'; // 更隐蔽SNI
const ALPN = 'h3';
const ARCH = os.arch().includes('arm64') || os.arch().includes('aarch64') ? 'arm64' : 'amd64';
const BIN_NAME = `hysteria-linux-${ARCH}`;
const PSEUDO_BIN_NAME = 'sysd'; // 伪装进程名
const PASS_FILE = '.hy2_pass';

// 获取端口（命令行优先，否则随机）
const SERVER_PORT = process.argv[2] || DEFAULT_PORT;

// 防止重复运行
try {
  const pid = execSync(`pidof ${PSEUDO_BIN_NAME}`).toString().trim();
  if (pid) process.exit(0);
} catch (e) {}

// 强密码（复用或生成）
let AUTH_PASSWORD;
if (fs.existsSync(PASS_FILE)) {
  AUTH_PASSWORD = fs.readFileSync(PASS_FILE, 'utf8').trim();
} else {
  AUTH_PASSWORD = crypto.randomBytes(16).toString('hex');
  fs.writeFileSync(PASS_FILE, AUTH_PASSWORD);
  fs.chmodSync(PASS_FILE, 0o600);
}

// 下载二进制（静默）
const downloadBinary = () => {
  if (fs.existsSync(PSEUDO_BIN_NAME)) return;
  const url = `https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}`;
  const file = fs.createWriteStream(BIN_NAME);
  https.get(url, (response) => {
    response.pipe(file);
    file.on('finish', () => {
      file.close();
      fs.chmodSync(BIN_NAME, 0o755);
      fs.renameSync(BIN_NAME, PSEUDO_BIN_NAME);
    });
  }).on('error', () => process.exit(1));
};

// 生成证书（静默）
const ensureCert = () => {
  if (fs.existsSync(CERT_FILE) && fs.existsSync(KEY_FILE)) return;
  execSync(`openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -keyout ${KEY_FILE} -out ${CERT_FILE} -subj "/CN=${SNI}"`, { stdio: 'ignore' });
};

// 写配置文件（优化CPU/带宽）
const writeConfig = () => {
  const config = `
listen: ":${SERVER_PORT}"
tls:
  cert: "${path.resolve(CERT_FILE)}"
  key: "${path.resolve(KEY_FILE)}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
bandwidth:
  up: "20mbps"
  down: "50mbps"
quic:
  max_idle_timeout: "120s"
  max_concurrent_streams: 8  # 降低并发
  keepAlivePeriod: 60s
  initial_stream_receive_window: 32768  # 减小窗口
  max_stream_receive_window: 65536
  initial_conn_receive_window: 65536
  max_conn_receive_window: 131072
`;
  fs.writeFileSync('server.yaml', config.trim());
};

// 安装cpulimit（如果未安装，静默）
const installCpulimit = () => {
  try {
    execSync('command -v cpulimit', { stdio: 'ignore' });
  } catch (e) {
    try {
      if (execSync('command -v apt').toString()) {
        execSync('apt update -qq && apt install -y cpulimit', { stdio: 'ignore' });
      } else if (execSync('command -v yum').toString()) {
        execSync('yum install -y epel-release && yum install -y cpulimit', { stdio: 'ignore' });
      }
    } catch (err) {}
  }
};

// 主逻辑
downloadBinary();
ensureCert();
writeConfig();
installCpulimit();

// 启动（CPU限15%，后台静默）
const hasCpulimit = () => {
  try {
    execSync('command -v cpulimit', { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false;
  }
};

const cmd = hasCpulimit()
  ? `cpulimit -l 15 -e ${PSEUDO_BIN_NAME} & ./${PSEUDO_BIN_NAME} server -c server.yaml >/dev/null 2>&1`
  : `nice -n 19 ./${PSEUDO_BIN_NAME} server -c server.yaml >/dev/null 2>&1`;

spawn('nohup', ['bash', '-c', cmd], { detached: true, stdio: 'ignore' }).unref();

// 清理痕迹
try { fs.unlinkSync(BIN_NAME); } catch (e) {}
