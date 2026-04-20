# Hetzner Server Setup — Design Spec

**Date:** 2026-04-20
**Status:** Approved

## Overview

A single idempotent bash script (`setup.sh`) that provisions a fresh Hetzner Debian server with security best practices, Coolify as the app platform, and all supporting infrastructure. Run once as root; safe to re-run. Future servers for scale-out use the same script.

---

## Context

- **Server:** Hetzner CX42, Debian, Falkenstein (Germany, EU)
- **Operator:** Solo (lxadmin), team access added later via Tailscale
- **Apps:** Worldwide users, GDPR applies (data stays in EU)
- **Access model:** SSH locked to home IP + Tailscale; admin UIs Tailscale-only
- **Hetzner Cloud Firewall:** Already configured (80/443 open, 22 limited to home IP)

---

## Architecture

```
Internet
  ├── :80/:443 ──► Hetzner FW ──► UFW ──► CrowdSec ──► Traefik (Coolify)
  │                                                          ├── Apps
  │                                                          ├── Postgres
  │                                                          ├── Redis
  │                                                          └── MinIO
  │
  └── :22 ──► Hetzner FW (home IP only) ──► UFW (home IP + Tailscale) ──► sshd

Admin UIs (Tailscale-only):
  - Coolify dashboard   :8000
  - MinIO console       :9001

Backups:
  MinIO ──► rclone crypt ──► Hetzner Object Storage (nightly, AES-256)

Monitoring:
  Grafana Alloy ──► Grafana Cloud (metrics + logs)

Notifications (Discord, switchable to Slack):
  - SSH login detected
  - Reboot required (pending security update)
```

---

## Security Layers

| Layer | Mechanism |
|---|---|
| Network (L3) | Hetzner Cloud Firewall |
| Host firewall | UFW + logged blocked attempts |
| Threat intelligence | CrowdSec (community blocklist) |
| SSH | Key-only, root disabled, home IP + Tailscale only |
| Admin UIs | Tailscale-only (not exposed to internet) |
| Container runtime | Docker daemon hardened (`no-new-privileges`, AppArmor) |
| Proxy headers | Traefik global middleware (HSTS, X-Frame, nosniff, rate limit) |
| Audit | auditd (GDPR baseline) |
| Backups | rclone crypt (AES-256) before upload |
| OS patches | unattended-upgrades (non-reboot auto, reboot → Discord alert) |

---

## Configuration Block

All secrets and environment-specific values live at the top of `setup.sh`. Nothing else needs editing.

```bash
DEPLOY_USER="lxadmin"
HOME_IP="x.x.x.x"                    # https://ifconfig.me
WEBHOOK_URL="https://discord.com/api/webhooks/..."
WEBHOOK_TYPE="discord"               # "discord" or "slack"
HETZNER_BUCKET="your-bucket-name"
HETZNER_ACCESS_KEY="..."
HETZNER_SECRET_KEY="..."
HETZNER_REGION="fsn1"
RCLONE_CRYPT_PASS="..."              # openssl rand -base64 32
RCLONE_CRYPT_PASS2="..."
GRAFANA_CLOUD_METRICS_URL="..."
GRAFANA_CLOUD_LOGS_URL="..."
GRAFANA_CLOUD_USER_ID="123456"
GRAFANA_CLOUD_API_KEY="glc_..."
TAILSCALE_AUTH_KEY="tskey-auth-..."
SWAP_SIZE="4G"
```

---

## Script Phases

Each phase is idempotent — safe to re-run if setup fails partway through.

### Phase 1 — System user + SSH hardening + login alert
- Create `lxadmin` with sudo, copy root's authorized SSH keys
- `sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`
- sshrc hook: on SSH login, fire `notify()` with timestamp + source IP → Discord

### Phase 2 — Hetzner Private Network interface config
- Configure `eth1` with static private IP (auto-detected from Hetzner metadata)
- Private IP found in Hetzner Console → Server → Networking → Private Networks
- Enables free inter-server traffic when a second server is added later

### Phase 3 — UFW firewall + logging
- Default: deny incoming, allow outgoing
- Allow: 22 from `$HOME_IP` only, 80/443 from anywhere
- `ufw logging on` — blocked attempts visible in Loki/Grafana

### Phase 4 — Tailscale
- Install via official script, auth with `$TAILSCALE_AUTH_KEY`
- UFW: allow SSH from Tailscale subnet (`100.64.0.0/10`)

### Phase 5 — CrowdSec
- Install CrowdSec agent + Traefik bouncer
- Enroll in community blocklist (auto-blocks known bad IPs)
- CrowdSec Hub: install `linux`, `traefik`, `ssh` collections

### Phase 6 — Swap file
- Create `$SWAP_SIZE` swap at `/swapfile`
- `swappiness=10` (prefer RAM, use swap as safety net)
- Persisted in `/etc/fstab`

### Phase 7 — unattended-upgrades + reboot webhook
- `Automatic-Reboot: false` — never reboots without permission
- Systemd timer (daily 09:00): check `/var/run/reboot-required`, fire `notify()` if present
- Non-security updates also auto-applied

### Phase 8 — Docker + hardened daemon.json
- Install Docker CE from official apt repo
- Add `lxadmin` to `docker` group
- `daemon.json`: `no-new-privileges`, live-restore, log rotation (10m/3 files), ulimits
- AppArmor enabled by default on Debian

### Phase 9 — Coolify install
- Official Coolify install script
- Coolify manages: Postgres, Redis, MinIO as Docker containers
- Dashboard on :8000 (Tailscale-only), MinIO console on :9001 (Tailscale-only)

### Phase 10 — Traefik global security middleware
- Global middleware applied to all routes:
  - HSTS (1 year), X-Frame-Options: DENY, X-Content-Type-Options: nosniff
  - Referrer-Policy, Permissions-Policy
- Rate limiting: 100 req/s per IP, burst 200

### Phase 11 — auditd (GDPR baseline)
- Rules: auth events, sudo usage, /etc/ writes, SSH key changes
- Logs forwarded to Loki via Grafana Alloy

### Phase 12 — rclone + encrypted backup
- rclone crypt remote over Hetzner Object Storage (S3-compatible)
- AES-256 encrypted client-side before upload
- Nightly cron (02:00): Postgres dumps, MinIO data, Coolify config

### Phase 13 — Grafana Alloy
- Metrics: CPU, RAM, disk, network, Docker containers
- Logs: syslog, auth.log, UFW blocked, Docker stdout, backup.log
- Dashboards: Node Exporter Full (1860), Docker (10619), Loki (13639)

### Phase 14 — lynis security audit
- One-time audit at end of setup
- Report saved to `/root/lynis-report.txt`
- Hardening index printed to terminal

---

## Notification System

Single `notify()` function handles Discord and Slack. Switch by changing 2 lines in config.

Triggers: SSH login, reboot required (daily check), setup complete.

---

## Prerequisites Checklist

- [x] Hetzner Cloud Firewall configured (80/443 open, 22 limited to home IP)
- [ ] Domain DNS A record pointing to server IP
- [ ] Hetzner Private Network created and attached to server; note the assigned private IP
- [ ] Hetzner Object Storage bucket created (region: Falkenstein)
- [ ] Hetzner Object Storage access key generated
- [ ] Grafana Cloud account created, stack provisioned
- [ ] Tailscale account, auth key generated (one-time use)
- [ ] Discord webhook URL created
- [ ] rclone crypt passphrases generated (`openssl rand -base64 32`)
- [ ] Config block in `setup.sh` filled in

---

## Multi-Server Expansion

1. Provision new Hetzner CX42 in same datacenter
2. Add to same Hetzner Private Network
3. Run `setup.sh` on new server
4. Coolify dashboard: Servers → Add Server → SSH into new server
5. Coolify installs agent, server ready for deployments

---

## Approach Alternatives

**Option A (chosen) — Bash script:** Single idempotent script. No local tooling. Easy to audit.

**Option B — Ansible playbook:** Declarative, structured. Migrate at 3+ servers or team growth.

**Option C — cloud-init:** Zero-touch provisioning from Hetzner server creation. Best for frequent re-provisioning.
