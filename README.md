# Dante SOCKS5 Proxy — One-Click Installer

Performance-optimised Dante SOCKS5 proxy for Ubuntu. **TCP only, no UDP.**

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/asdasd070511/dante-socks5-install/main/install.sh)
```

Or with preset credentials (non-interactive):

```bash
curl -fsSL https://raw.githubusercontent.com/asdasd070511/dante-socks5-install/main/install.sh \
  | PROXY_USER=myuser PROXY_PASS=mypass PROXY_PORT=1080 sudo bash
```

## What It Does

- Installs `dante-server` on Ubuntu
- Configures SOCKS5 with username/password auth
- **TCP only** — all UDP is explicitly blocked
- Applies kernel-level TCP performance tuning
- Auto-detects network interface and IP

## Performance Optimisations

| Category | Details |
|----------|---------|
| Congestion | BBR algorithm |
| Latency | TCP Fast Open (client + server) |
| Buffers | 256 KB default / 16 MB max socket buffers |
| Connections | somaxconn 65535, TIME_WAIT reuse, FIN timeout 15s |
| Keepalive | 300s idle / 15s interval / 5 probes |
| Throughput | `tcp_slow_start_after_idle = 0`, MTU probing |
| System | 1M file descriptors, Nice -10, auto-restart |

## Test

```bash
curl -x socks5h://user:pass@YOUR_IP:1080 https://ifconfig.me
```

## Management

```bash
sudo systemctl status danted
sudo systemctl restart danted
sudo journalctl -u danted -f
```

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04
- Root access

## License

MIT
