# Hetzner Server Setup

Idempotent bash script to provision a secure Hetzner Debian server ready for app deployments via Coolify.

## What it does

Runs 14 phases in sequence, each safe to re-run:

| Phase | What |
|---|---|
| 1 | Create deploy user (`lxadmin`), harden SSH, Discord login alerts |
| 2 | Configure Hetzner Private Network interface |
| 3 | UFW firewall (80/443 public, SSH home IP + Tailscale only) |
| 4 | Tailscale VPN |
| 5 | CrowdSec + Traefik bouncer (community threat intelligence) |
| 6 | Swap file (4GB, swappiness=10) |
| 7 | unattended-upgrades + Discord reboot notification |
| 8 | Docker CE with hardened `daemon.json` |
| 9 | Coolify (manages Postgres, Redis, MinIO, Traefik) |
| 10 | Traefik global security headers + rate limiting |
| 11 | auditd GDPR baseline rules |
| 12 | rclone + AES-256 encrypted backup → Hetzner Object Storage |
| 13 | Grafana Alloy → Grafana Cloud (metrics + logs) |
| 14 | lynis security audit |

## Prerequisites

- [ ] Hetzner Cloud Firewall: 80/443 open, 22 limited to home IP
- [ ] Domain DNS A record pointing to server IP
- [ ] Hetzner Private Network created and attached to server
- [ ] Hetzner Object Storage bucket + access key
- [ ] Grafana Cloud account + stack
- [ ] Tailscale account + one-time auth key
- [ ] Discord webhook URL
- [ ] rclone crypt passphrases: `openssl rand -base64 32`

## Usage

```bash
# 1. Fill in the config block at top of setup.sh
vim setup.sh

# 2. Transfer to server
scp setup.sh root@<server-ip>:/root/setup.sh

# 3. Run
ssh root@<server-ip> "bash /root/setup.sh 2>&1 | tee /root/setup.log"
```

## Security model

```
Internet → Hetzner FW → UFW → CrowdSec → Traefik → Apps
SSH: home IP + Tailscale only
Admin UIs (Coolify :8000, MinIO :9001): Tailscale-only
Backups: AES-256 encrypted before upload
```

## Switching Discord → Slack

Change two lines in the config block:
```bash
WEBHOOK_URL="https://hooks.slack.com/services/..."
WEBHOOK_TYPE="slack"
```

## Adding a second server

1. Provision new Hetzner server in same datacenter
2. Add to same Hetzner Private Network
3. Run `setup.sh` on new server
4. Coolify UI → Servers → Add Server

## Docs

- [Design spec](docs/superpowers/specs/2026-04-20-hetzner-server-setup-design.md)
- [Implementation plan](docs/superpowers/plans/2026-04-20-hetzner-server-setup.md)
- [Visual spec (HTML)](docs/superpowers/specs/2026-04-20-hetzner-server-setup.html)
