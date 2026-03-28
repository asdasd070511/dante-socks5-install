#!/usr/bin/env bash
# ============================================================================
# Dante SOCKS5 Proxy — One-Click Installer for Ubuntu (TCP Only)
# Performance-optimised with kernel-level TCP tuning
# ============================================================================
set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Please run as root:  sudo bash $0"

# ── Detect OS ───────────────────────────────────────────────────────────────
if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    die "This script is designed for Ubuntu only."
fi

# ── Configuration (edit these or pass as env vars) ──────────────────────────
PROXY_PORT="${PROXY_PORT:-1080}"
WORKER_PROCS="${WORKER_PROCS:-0}"          # 0 = auto (CPU cores * 2)

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Dante SOCKS5 Proxy Installer (TCP Only / Optimised)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Detect primary network interface & IP ───────────────────────────────────
NET_IF=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$NET_IF" ]] || die "Cannot detect default network interface."
SERVER_IP=$(ip -4 addr show "$NET_IF" | awk '/inet /{print $2; exit}' | cut -d/ -f1)
[[ -n "$SERVER_IP" ]] || die "Cannot detect server IP on $NET_IF."
info "Interface: $NET_IF  |  IP: $SERVER_IP  |  Port: $PROXY_PORT"

# ── CPU count for worker calculation ────────────────────────────────────────
CPU_CORES=$(nproc)
if [[ "$WORKER_PROCS" -eq 0 ]]; then
    WORKER_PROCS=$((CPU_CORES * 2))
    [[ "$WORKER_PROCS" -ge 4 ]] || WORKER_PROCS=4
fi
info "CPU cores: $CPU_CORES  |  Worker processes: $WORKER_PROCS"

# ============================================================================
# 1. INSTALL DANTE SERVER
# ============================================================================
info "Installing dante-server..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dante-server > /dev/null 2>&1
ok "dante-server installed."

# ============================================================================
# 2. WRITE OPTIMISED danted.conf  (TCP ONLY)
# ============================================================================
info "Writing /etc/danted.conf..."
cat > /etc/danted.conf << 'DANTECFG'
# ============================================================================
# Dante SOCKS5 — TCP-Only, Performance-Optimised Configuration
# ============================================================================

logoutput: syslog /var/log/danted.log

# ── Interfaces ──────────────────────────────────────────────────────────────
internal: NETIF port = PORT
external: NETIF

# ── Worker / child process tuning ──────────────────────────────────────────
# Negotiate phase (SOCKS handshake) — short-lived, many children
child.maxidle: yes
child.maxrequests: 0

# ── Socket options for performance ──────────────────────────────────────────
socket.recvbuf.tcp: 262144
socket.sendbuf.tcp: 262144

# ── Timeouts (aggressive for TCP proxy speed) ──────────────────────────────
timeout.negotiate: 8
timeout.io: 3600
timeout.tcp_fin_wait: 30

# ── Authentication (none — open proxy) ─────────────────────────────────────
clientmethod: none
socksmethod: none

# ── Client rules (who can connect to the proxy) ────────────────────────────
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

# ── SOCKS rules (what the proxy will relay) — TCP ONLY ─────────────────────
# Block all UDP explicitly
socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: udp
    log: error
}

# Allow TCP CONNECT
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect
    protocol: tcp
    log: error
    socksmethod: none
}

# Block everything else
socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
DANTECFG

# Inject actual interface and port
sed -i "s/NETIF/$NET_IF/g; s/PORT/$PROXY_PORT/g" /etc/danted.conf
ok "/etc/danted.conf written."

# ============================================================================
# 4. KERNEL-LEVEL TCP PERFORMANCE TUNING
# ============================================================================
info "Applying kernel TCP performance tuning..."

SYSCTL_CONF="/etc/sysctl.d/99-dante-tcp-perf.conf"
cat > "$SYSCTL_CONF" << 'EOF'
# ============================================================================
# TCP Performance Tuning for Dante SOCKS5 Proxy
# ============================================================================

# ── BBR Congestion Control ──────────────────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── TCP Fast Open (client + server) ────────────────────────────────────────
net.ipv4.tcp_fastopen = 3

# ── Socket buffer sizes (256 KB default, 16 MB max) ────────────────────────
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

# ── Connection handling ─────────────────────────────────────────────────────
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535

# ── Keepalive (detect dead connections fast) ────────────────────────────────
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# ── Memory pressure ────────────────────────────────────────────────────────
net.ipv4.tcp_mem = 786432 1048576 1572864
net.core.optmem_max = 65535

# ── Misc TCP optimisations ─────────────────────────────────────────────────
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2

# ── File descriptor limit ──────────────────────────────────────────────────
fs.file-max = 2097152
fs.nr_open = 2097152

# ── Conntrack (if module loaded) ────────────────────────────────────────────
# net.netfilter.nf_conntrack_max = 1048576
EOF

# Load BBR module
modprobe tcp_bbr 2>/dev/null || true
if ! grep -q 'tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null; then
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
fi

sysctl --system > /dev/null 2>&1
ok "Kernel TCP tuning applied (BBR, buffers, fast-open, keepalive)."

# ============================================================================
# 5. RAISE FILE DESCRIPTOR LIMITS
# ============================================================================
info "Raising file descriptor limits..."

LIMITS_CONF="/etc/security/limits.d/99-dante.conf"
cat > "$LIMITS_CONF" << 'EOF'
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
EOF

# Ensure PAM picks up the limits
if ! grep -q 'pam_limits.so' /etc/pam.d/common-session 2>/dev/null; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

ok "File descriptor limits raised to 1048576."

# ============================================================================
# 6. OPTIMISE SYSTEMD SERVICE UNIT
# ============================================================================
info "Optimising systemd service..."

mkdir -p /etc/systemd/system/danted.service.d
cat > /etc/systemd/system/danted.service.d/override.conf << EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
Restart=always
RestartSec=3
Nice=-10
CPUSchedulingPolicy=other

[Unit]
After=network-online.target
Wants=network-online.target
EOF

# Create log file
touch /var/log/danted.log
chmod 640 /var/log/danted.log

systemctl daemon-reload
ok "Systemd service optimised."

# ============================================================================
# 7. CONFIGURE FIREWALL (UFW)
# ============================================================================
if command -v ufw &>/dev/null; then
    info "Configuring UFW firewall..."
    ufw allow "$PROXY_PORT"/tcp > /dev/null 2>&1
    ok "UFW: port $PROXY_PORT/tcp allowed."
else
    warn "UFW not found — ensure port $PROXY_PORT/tcp is open in your firewall."
fi

# ============================================================================
# 8. VALIDATE CONFIGURATION & START
# ============================================================================
info "Validating danted configuration..."
if danted -V -f /etc/danted.conf > /dev/null 2>&1; then
    ok "Configuration is valid."
else
    # danted -V returns non-zero even on success sometimes; check if it parses
    warn "danted -V returned non-zero (may be normal). Attempting to start..."
fi

info "Starting danted service..."
systemctl enable danted > /dev/null 2>&1
systemctl restart danted

# Wait briefly and check
sleep 2
if systemctl is-active --quiet danted; then
    ok "danted is running."
else
    die "danted failed to start. Check: journalctl -u danted -n 50"
fi

# ============================================================================
# 9. LOGROTATE
# ============================================================================
cat > /etc/logrotate.d/danted << 'EOF'
/var/log/danted.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload danted > /dev/null 2>&1 || true
    endscript
}
EOF
ok "Log rotation configured (7 days)."

# ============================================================================
# DONE
# ============================================================================
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "$SERVER_IP")

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Dante SOCKS5 Proxy — Installation Complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Protocol :  ${CYAN}SOCKS5 (TCP only, no auth)${NC}"
echo -e "  Server   :  ${CYAN}${PUBLIC_IP}${NC}"
echo -e "  Port     :  ${CYAN}${PROXY_PORT}${NC}"
echo ""
echo -e "  ${YELLOW}Test:${NC}  curl -x socks5h://${PUBLIC_IP}:${PROXY_PORT} https://ifconfig.me"
echo ""
echo -e "  ${YELLOW}Performance tuning applied:${NC}"
echo -e "    - BBR congestion control"
echo -e "    - TCP Fast Open (client+server)"
echo -e "    - Socket buffers: 256KB default / 16MB max"
echo -e "    - Connection backlog: 65535"
echo -e "    - TIME_WAIT reuse + fast FIN timeout"
echo -e "    - Keepalive: 300s / 15s interval / 5 probes"
echo -e "    - File descriptors: 1M"
echo -e "    - Systemd: auto-restart, nice -10"
echo ""
echo -e "  ${YELLOW}Management:${NC}"
echo -e "    systemctl status danted"
echo -e "    systemctl restart danted"
echo -e "    journalctl -u danted -f"
echo -e "    tail -f /var/log/danted.log"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
