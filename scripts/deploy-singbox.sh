#!/usr/bin/env bash
#
# ============================================================================
#  自建 VPS 一键部署：sing-box (Hysteria2 + VLESS-Reality)
#  适用：Ubuntu 22.04 / 24.04，全新 VPS，root 权限
#  用法：sudo bash deploy-singbox.sh
#  交付：部署完成后自动生成客户端配置到 /root/client-configs/
# ============================================================================
#
#  设计说明（重要）
#  ---------------------------------------------------------------------------
#  * 协议双栈：
#      - Hysteria2 (UDP/8443) : 基于 QUIC + 内置 BBR，弱网/家宽速度最好
#      - VLESS-Reality (TCP/443): 借用真实大站 TLS 握手特征，抗主动探测
#  * 不需要域名、不需要 SSL 证书、不需要备案
#      - Reality 复用外部大站的 TLS 特征
#      - Hysteria2 用本机自签证书（HY2 自带加密层，自签完全够用）
#  * 兼容 sing-box 1.14.x；已规避 1.11 起被弃用的入站 sniff/domain_strategy 字段
#  * 脚本最后会执行 `sing-box check` 校验配置，校验不过不会启动服务
#
set -euo pipefail

# ------------------------------ 可调参数 ------------------------------------
HY2_PORT=8443                 # Hysteria2 监听端口（UDP）
REALITY_PORT=443              # VLESS-Reality 监听端口（TCP）
REALITY_SERVERNAME="www.microsoft.com"   # Reality 伪装目标（SNI）
SSH_PORT=22                   # 你的 SSH 端口，用于放行防火墙
# ---------------------------------------------------------------------------

RED=$'\e[31m'; GREEN=$'\e[92m'; YELLOW=$'\e[33m'; CYAN=$'\e[96m'; NONE=$'\e[0m'
info()  { echo -e "${CYAN}[*]${NONE} $*"; }
ok()    { echo -e "${GREEN}[✓]${NONE} $*"; }
warn()  { echo -e "${YELLOW}[!]${NONE} $*"; }
die()   { echo -e "${RED}[✗]${NONE} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行： sudo bash $0"

# ============================ 1. 系统检查 ===================================
info "检查系统环境..."
. /etc/os-release 2>/dev/null || die "无法识别系统版本"
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] || warn "非 Ubuntu/Debian（当前 $ID），脚本可能不适用"

CODENAME="${VERSION_CODENAME:-}"
info "系统：$PRETTY_NAME"

info "更新软件源..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget openssl jq ufw fail2ban ca-certificates >/dev/null

# ============================ 2. 开启 BBR ===================================
info "开启 BBR 拥塞控制..."
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null 2>&1 || true
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
  ok "BBR 已启用"
else
  warn "BBR 未生效（部分 OpenVZ 容器不支持，KVM 才支持）"
fi

# 网络性能调优
cat > /etc/sysctl.d/99-network-tuning.conf <<'EOF'
fs.file-max = 1000000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
EOF
sysctl --system >/dev/null 2>&1 || true
ok "网络参数调优完成"

# ============================ 3. 安装 sing-box ==============================
info "安装 sing-box（官方源）..."
if ! command -v sing-box >/dev/null 2>&1; then
  curl -fsSL https://sing-box.app/install.sh | sh || die "sing-box 安装失败"
fi
SB_VER="$(sing-box version 2>/dev/null | head -1 || echo unknown)"
ok "sing-box 就绪：$SB_VER"

# 确认 systemd 服务存在
[[ -f /etc/systemd/system/sing-box.service ]] || warn "未找到 sing-box.service，稍后将手动创建"

# ============================ 4. 生成凭据 ===================================
info "生成密钥与凭据..."
UUID="$(sing-box generate uuid)"
HY2_PASS="$(sing-box generate rand --hex 16)"
SHORT_ID="$(sing-box generate rand --hex 8)"

# Reality x25519 密钥对
KP="$(sing-box generate reality-keypair)"
PRIV_KEY="$(echo "$KP" | awk -F': *' '/PrivateKey/{print $2}' | tr -d ' \r')"
PUB_KEY="$(echo "$KP"  | awk -F': *' '/PublicKey/{print $2}'  | tr -d ' \r')"
[[ -n "$PRIV_KEY" && -n "$PUB_KEY" ]] || die "Reality 密钥生成失败，输出：$KP"

# Hysteria2 自签证书
info "生成 Hysteria2 自签证书（10 年有效）..."
mkdir -p /etc/sing-box/certs
openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/certs/hy2.key >/dev/null 2>&1
openssl req -new -x509 -days 3650 -key /etc/sing-box/certs/hy2.key \
  -out /etc/sing-box/certs/hy2.crt -subj "/CN=www.bing.com" >/dev/null 2>&1
chmod 600 /etc/sing-box/certs/hy2.key
ok "证书已生成"

# 探测服务器公网 IP
SERVER_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[[ -n "$SERVER_IP" ]] || die "无法探测公网 IP，请手动填写"
ok "服务器公网 IP：$SERVER_IP"

# ============================ 5. 写入服务端配置 ==============================
info "写入 sing-box 配置..."
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        { "password": "${HY2_PASS}" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/hy2.crt",
        "key_path": "/etc/sing-box/certs/hy2.key"
      }
    },
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVERNAME}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SERVERNAME}",
            "server_port": 443
          },
          "private_key": "${PRIV_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
chmod 600 /etc/sing-box/config.json

info "校验配置..."
if sing-box check -c /etc/sing-box/config.json; then
  ok "配置校验通过"
else
  die "配置校验失败，请把上面的报错发给我。配置保留在 /etc/sing-box/config.json"
fi

# ============================ 6. 防火墙 =====================================
info "配置防火墙（ufw）..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}"/tcp comment 'SSH' >/dev/null
ufw allow "${REALITY_PORT}"/tcp comment 'sing-box Reality' >/dev/null
ufw allow "${HY2_PORT}"/udp comment 'sing-box Hysteria2' >/dev/null
ufw --force enable >/dev/null
ok "防火墙已启用：放行 ${SSH_PORT}/tcp, ${REALITY_PORT}/tcp, ${HY2_PORT}/udp"

# ============================ 7. fail2ban + 自动更新 =========================
info "配置 fail2ban..."
systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban 启动失败（不影响代理）"

info "配置每 20 天自动更新..."
cat > /etc/cron.d/vps-maintenance <<'EOF'
# 每 20 天凌晨 3 点更新系统与 sing-box 内核
0 3 */20 * * root (apt-get update -qq && apt-get -y -qq upgrade && curl -fsSL https://sing-box.app/install.sh | sh && systemctl restart sing-box) >> /var/log/vps-maintenance.log 2>&1
EOF
chmod 644 /etc/cron.d/vps-maintenance
ok "自动维护任务已写入 /etc/cron.d/vps-maintenance"

# ============================ 8. 启动服务 ===================================
info "启动 sing-box..."
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 3

if systemctl is-active --quiet sing-box; then
  ok "sing-box 运行中"
else
  warn "sing-box 未启动，最近日志："
  journalctl -u sing-box --no-pager -n 30 || true
  die "启动失败"
fi

# ============================ 9. 生成客户端配置 ==============================
OUT=/root/client-configs
mkdir -p "$OUT"

# --- Clash Meta / Mihomo YAML ---
cat > "$OUT/clash-verge.yaml" <<EOF
# ============================================================
# Clash Meta (Mihomo) 配置 — 适用于 Clash Verge Rev / ClashX Meta
# 服务器: ${SERVER_IP}
# 生成时间: $(date -Iseconds)
# ============================================================
mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: false

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.1.1.1/dns-query

proxies:
  - name: "VPS-HY2"
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY2_PORT}
    password: "${HY2_PASS}"
    sni: www.bing.com
    alpn:
      - h3
    skip-cert-verify: true
    up: "50 Mbps"
    down: "200 Mbps"

  - name: "VPS-Reality"
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SERVERNAME}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: "${SHORT_ID}"

proxy-groups:
  - name: "PROXY"
    type: fallback
    proxies:
      - "VPS-HY2"
      - "VPS-Reality"
    url: "http://www.gstatic.com/generate_204"
    interval: 300

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

# --- sing-box 客户端配置（Windows TUN 模式）---
cat > "$OUT/singbox-client.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "https", "tag": "dns-proxy", "server": "1.1.1.1", "detour": "VPS-HY2" },
      { "type": "https", "tag": "dns-direct", "server": "223.5.5.5", "detour": "direct" }
    ],
    "rules": [
      { "rule_set": "geosite-cn", "server": "dns-direct" }
    ],
    "final": "dns-proxy",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": 7890
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "strict_route": false,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "VPS-HY2",
      "server": "${SERVER_IP}",
      "server_port": ${HY2_PORT},
      "password": "${HY2_PASS}",
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "alpn": ["h3"],
        "insecure": true
      }
    },
    {
      "type": "vless",
      "tag": "VPS-Reality",
      "server": "${SERVER_IP}",
      "server_port": ${REALITY_PORT},
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVERNAME}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "${PUB_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "default_domain_resolver": { "server": "dns-direct" },
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" },
      { "rule_set": "geoip-cn", "outbound": "direct" }
    ],
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "direct"
      }
    ],
    "final": "VPS-HY2",
    "auto_detect_interface": true
  }
}
EOF

# --- 纯文本参数备份 ---
cat > "$OUT/params.txt" <<EOF
================= 自建节点参数（请妥善保存） =================
服务器 IP        : ${SERVER_IP}
生成时间         : $(date -Iseconds)

--- Hysteria2 ---
协议             : hysteria2
端口             : ${HY2_PORT}  (UDP)
密码             : ${HY2_PASS}
SNI              : www.bing.com
ALPN             : h3

--- VLESS + Reality ---
协议             : vless
端口             : ${REALITY_PORT}  (TCP)
UUID             : ${UUID}
流控 Flow        : xtls-rprx-vision
SNI              : ${REALITY_SERVERNAME}
公钥 PublicKey   : ${PUB_KEY}
ShortId          : ${SHORT_ID}
指纹 Fingerprint : chrome

--- 服务端私钥（勿外泄，仅备份用） ---
Reality PrivateKey : ${PRIV_KEY}
EOF
chmod 600 "$OUT/params.txt"

# ============================ 10. 汇总输出 ==================================
echo
echo "======================================================================"
echo -e "${GREEN}  部署完成${NONE}"
echo "======================================================================"
echo
echo -e "${CYAN}服务器信息${NONE}"
echo "  公网 IP      : ${SERVER_IP}"
echo "  Reality      : ${REALITY_PORT}/tcp   (VLESS + Vision)"
echo "  Hysteria2    : ${HY2_PORT}/udp"
echo
echo -e "${CYAN}客户端配置已生成于 ${OUT}/${NONE}"
echo "  clash-verge.yaml    → Clash Verge Rev / Mihomo 直接导入"
echo "  singbox-client.json → sing-box 客户端（Windows TUN 模式）"
echo "  params.txt          → 全部参数明文备份"
echo
echo -e "${CYAN}Reality 关键参数（手动配置时需要）${NONE}"
echo "  UUID        : ${UUID}"
echo "  公钥        : ${PUB_KEY}"
echo "  ShortId     : ${SHORT_ID}"
echo "  SNI         : ${REALITY_SERVERNAME}"
echo
echo -e "${CYAN}Hysteria2 关键参数${NONE}"
echo "  密码        : ${HY2_PASS}"
echo "  SNI         : www.bing.com"
echo
echo -e "${YELLOW}常用管理命令${NONE}"
echo "  systemctl status sing-box      # 查看状态"
echo "  systemctl restart sing-box     # 重启"
echo "  journalctl -u sing-box -f      # 实时日志"
echo "  sing-box check -c /etc/sing-box/config.json   # 校验配置"
echo
echo -e "${YELLOW}请立即执行（重要）${NONE}"
echo "  1. 把 ${OUT}/ 下的文件下载到本机："
echo "     scp -r root@${SERVER_IP}:${OUT} ./client-configs"
echo "  2. 在本机测通之后再考虑关闭现有代理"
echo
echo "======================================================================"
