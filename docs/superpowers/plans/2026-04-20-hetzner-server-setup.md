# Hetzner Server Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a single idempotent `setup.sh` script that provisions a fresh Hetzner Debian server with security hardening, Coolify, encrypted backups, and observability.

**Architecture:** One bash script with 14 phase functions called in sequence. Each function checks whether its work is already done before acting (idempotent). Helper scripts are written to the filesystem during setup. All secrets live in the config block at the top of `setup.sh`.

**Tech Stack:** Bash, UFW, Tailscale, CrowdSec, Docker CE, Coolify, rclone, Grafana Alloy, auditd, lynis, unattended-upgrades, systemd

---

## File Map

**Created by the plan:**
- `setup.sh` — main script (all 14 phases as functions)

**Written to the server by the script during execution:**
- `/usr/local/bin/notify.sh` — webhook notification helper (Discord/Slack)
- `/usr/local/bin/ssh-notify.sh` — fires notify on SSH login
- `/usr/local/bin/check-reboot.sh` — daily reboot-required checker
- `/etc/ssh/sshd_config.d/hardening.conf` — SSH hardening overrides
- `/etc/ssh/sshrc` — per-login hook that calls ssh-notify
- `/etc/docker/daemon.json` — Docker daemon hardening
- `/etc/systemd/system/reboot-notifier.service` — systemd unit
- `/etc/systemd/system/reboot-notifier.timer` — daily timer
- `/etc/rclone/rclone.conf` — rclone + rclone crypt config
- `/etc/cron.d/nightly-backup` — 02:00 backup cron
- `/etc/alloy/config.alloy` — Grafana Alloy pipeline config
- `/etc/audit/rules.d/gdpr.rules` — auditd GDPR ruleset
- `/etc/traefik/dynamic/security-headers.yml` — Traefik global middleware

---

## Task 1: Script scaffold + config block + helpers

**Files:**
- Create: `setup.sh`

- [ ] **Step 1: Create setup.sh with scaffold**

```bash
cat > setup.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
DEPLOY_USER="lxadmin"
HOME_IP="x.x.x.x"
WEBHOOK_URL="https://discord.com/api/webhooks/..."
WEBHOOK_TYPE="discord"
HETZNER_BUCKET="your-bucket-name"
HETZNER_ACCESS_KEY="..."
HETZNER_SECRET_KEY="..."
HETZNER_REGION="fsn1"
RCLONE_CRYPT_PASS="..."
RCLONE_CRYPT_PASS2="..."
GRAFANA_CLOUD_METRICS_URL="https://prometheus-prod-xx.grafana.net/api/prom/push"
GRAFANA_CLOUD_LOGS_URL="https://logs-prod-xx.grafana.net/loki/api/v1/push"
GRAFANA_CLOUD_USER_ID="123456"
GRAFANA_CLOUD_API_KEY="glc_..."
TAILSCALE_AUTH_KEY="tskey-auth-..."
SWAP_SIZE="4G"
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash setup.sh"

notify() {
  local msg="$1"
  if [[ "$WEBHOOK_TYPE" == "slack" ]]; then
    curl -s -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" \
      -d "{\"text\": \"$msg\"}" || true
  else
    curl -s -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" \
      -d "{\"content\": \"$msg\"}" || true
  fi
}

main() {
  log "Starting server setup..."
  notify "🚀 Server setup started on $(hostname)"
}

main
SCRIPT
chmod +x setup.sh
```

- [ ] **Step 2: Verify scaffold**

```bash
bash -n setup.sh
echo "Exit: $?"
```
Expected: `Exit: 0`

- [ ] **Step 3: Commit**

```bash
git init
git add setup.sh
git commit -m "feat: scaffold setup.sh with config block and notify helper"
```

---

## Task 2: Phase 1 — System user + SSH hardening + login alert

- [ ] **Step 1: Write phase_1 function**

```bash
phase_1_user_ssh() {
  log "Phase 1: System user + SSH hardening..."

  if ! id "$DEPLOY_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$DEPLOY_USER
    chmod 440 /etc/sudoers.d/$DEPLOY_USER
  fi

  if [[ ! -f /home/$DEPLOY_USER/.ssh/authorized_keys ]]; then
    mkdir -p /home/$DEPLOY_USER/.ssh
    cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/authorized_keys
    chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh
    chmod 700 /home/$DEPLOY_USER/.ssh
    chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
  fi

  cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  cat > /usr/local/bin/notify.sh << NOTIFY
#!/usr/bin/env bash
MSG="\$1"
WEBHOOK_URL="${WEBHOOK_URL}"
WEBHOOK_TYPE="${WEBHOOK_TYPE}"
if [[ "\$WEBHOOK_TYPE" == "slack" ]]; then
  curl -s -X POST "\$WEBHOOK_URL" -H "Content-Type: application/json" -d "{\"text\": \"\$MSG\"}" || true
else
  curl -s -X POST "\$WEBHOOK_URL" -H "Content-Type: application/json" -d "{\"content\": \"\$MSG\"}" || true
fi
NOTIFY
  chmod +x /usr/local/bin/notify.sh

  cat > /usr/local/bin/ssh-notify.sh << 'SSHNOTIFY'
#!/usr/bin/env bash
SOURCE_IP="${SSH_CONNECTION%% *}"
/usr/local/bin/notify.sh "🔐 SSH login: $(whoami) from ${SOURCE_IP} at $(date '+%Y-%m-%d %H:%M:%S %Z')"
SSHNOTIFY
  chmod +x /usr/local/bin/ssh-notify.sh

  cat > /etc/ssh/sshrc << 'SSHRC'
#!/usr/bin/env bash
/usr/local/bin/ssh-notify.sh &
SSHRC
  chmod +x /etc/ssh/sshrc

  sshd -t && systemctl restart sshd
  log "Phase 1 complete ✓"
}
```

- [ ] **Step 2: Add to main() and verify syntax**

```bash
bash -n setup.sh && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add setup.sh && git commit -m "feat: phase 1 - deploy user, SSH hardening, login alert"
```

---

## Task 3: Phase 2 — Hetzner Private Network

- [ ] **Step 1: Add phase_2 function**

```bash
phase_2_private_network() {
  log "Phase 2: Hetzner Private Network interface..."

  if ! ip link show eth1 &>/dev/null; then
    warn "eth1 not found. Attach a Private Network in Hetzner console first. Skipping."
    return 0
  fi

  if ! grep -q "eth1" /etc/network/interfaces 2>/dev/null && \
     ! [[ -f /etc/systemd/network/10-eth1.network ]]; then
    PRIVATE_IP=$(curl -sf http://169.254.169.254/hetzner/v1/metadata/private-networks \
      | python3 -c "import sys,json; nets=json.load(sys.stdin); print(nets[0]['ip'])" 2>/dev/null || echo "")

    if [[ -z "$PRIVATE_IP" ]]; then
      warn "Could not detect private IP from metadata. Set eth1 manually if needed."
      return 0
    fi

    cat > /etc/systemd/network/10-eth1.network << EOF
[Match]
Name=eth1

[Network]
Address=${PRIVATE_IP}/16
EOF
    systemctl enable --now systemd-networkd
    networkctl reload || true
  fi

  log "Phase 2 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 2 - Hetzner private network eth1 config"
```

---

## Task 4: Phase 3 — UFW firewall

- [ ] **Step 1: Add phase_3 function**

```bash
phase_3_ufw() {
  log "Phase 3: UFW firewall..."
  apt-get install -y ufw > /dev/null

  if ! ufw status | grep -q "Status: active"; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow from "$HOME_IP" to any port 22 proto tcp comment "SSH home IP"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    ufw deny 8000/tcp comment "Coolify dashboard - internal only"
    ufw deny 9001/tcp comment "MinIO console - internal only"
    ufw logging on
    ufw --force enable
  else
    ufw allow from "$HOME_IP" to any port 22 proto tcp comment "SSH home IP" 2>/dev/null || true
  fi

  log "Phase 3 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 3 - UFW firewall with logging"
```

---

## Task 5: Phase 4 — Tailscale

- [ ] **Step 1: Add phase_4 function**

```bash
phase_4_tailscale() {
  log "Phase 4: Tailscale..."

  if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  if ! tailscale status &>/dev/null; then
    tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh=false
  fi

  ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment "SSH via Tailscale" 2>/dev/null || true

  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
  log "Tailscale IP: $TAILSCALE_IP"
  log "Phase 4 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 4 - Tailscale VPN"
```

---

## Task 6: Phase 5 — CrowdSec

- [ ] **Step 1: Add phase_5 function**

```bash
phase_5_crowdsec() {
  log "Phase 5: CrowdSec..."

  if ! command -v cscli &>/dev/null; then
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    apt-get install -y crowdsec
  fi

  if ! dpkg -l crowdsec-bouncer-traefik &>/dev/null 2>&1; then
    apt-get install -y crowdsec-bouncer-traefik 2>/dev/null || \
      cscli bouncers add traefik-bouncer 2>/dev/null || true
  fi

  cscli collections install crowdsecurity/linux   --force 2>/dev/null || true
  cscli collections install crowdsecurity/traefik  --force 2>/dev/null || true
  cscli collections install crowdsecurity/sshd     --force 2>/dev/null || true

  systemctl enable --now crowdsec
  cscli hub update 2>/dev/null || true
  log "Phase 5 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 5 - CrowdSec with Traefik bouncer"
```

---

## Task 7: Phase 6 — Swap file

- [ ] **Step 1: Add phase_6 function**

```bash
phase_6_swap() {
  log "Phase 6: Swap file..."

  if [[ ! -f /swapfile ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  sysctl -w vm.swappiness=10 > /dev/null
  grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
  log "Phase 6 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 6 - swap file"
```

---

## Task 8: Phase 7 — unattended-upgrades + reboot notifier

- [ ] **Step 1: Add phase_7 function**

```bash
phase_7_auto_updates() {
  log "Phase 7: Automatic updates + reboot notifier..."
  apt-get install -y unattended-upgrades apt-listchanges > /dev/null

  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}";
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > /usr/local/bin/check-reboot.sh << 'EOF'
#!/usr/bin/env bash
if [[ -f /var/run/reboot-required ]]; then
  PKGS=$(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
  /usr/local/bin/notify.sh "⚠️ Reboot required on $(hostname). Pending: ${PKGS:-unknown}. Please reboot at your convenience."
fi
EOF
  chmod +x /usr/local/bin/check-reboot.sh

  cat > /etc/systemd/system/reboot-notifier.service << 'EOF'
[Unit]
Description=Check and notify if reboot is required

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-reboot.sh
EOF

  cat > /etc/systemd/system/reboot-notifier.timer << 'EOF'
[Unit]
Description=Daily reboot-required check

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now reboot-notifier.timer
  log "Phase 7 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 7 - unattended-upgrades, reboot notifier"
```

---

## Task 9: Phase 8 — Docker + hardened daemon.json

- [ ] **Step 1: Add phase_8 function**

```bash
phase_8_docker() {
  log "Phase 8: Docker CE..."

  if ! command -v docker &>/dev/null; then
    apt-get install -y ca-certificates curl gnupg > /dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
  fi

  usermod -aG docker "$DEPLOY_USER"

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << 'EOF'
{
  "no-new-privileges": true,
  "live-restore": true,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-ulimits": { "nofile": { "Name": "nofile", "Hard": 64000, "Soft": 64000 } }
}
EOF

  systemctl enable docker
  systemctl restart docker
  log "Phase 8 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 8 - Docker CE with hardened daemon.json"
```

---

## Task 10: Phase 9 — Coolify

- [ ] **Step 1: Add phase_9 function**

```bash
phase_9_coolify() {
  log "Phase 9: Coolify..."

  if ! command -v coolify &>/dev/null && [[ ! -f /etc/coolify/coolify.conf ]]; then
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
  else
    log "Coolify already installed, skipping."
  fi

  ufw delete allow 8000/tcp 2>/dev/null || true
  ufw delete allow 9001/tcp 2>/dev/null || true
  ufw allow from 100.64.0.0/10 to any port 8000 proto tcp comment "Coolify - Tailscale only"
  ufw allow from 100.64.0.0/10 to any port 9001 proto tcp comment "MinIO console - Tailscale only"
  ufw reload

  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "your-tailscale-ip")
  log "Phase 9 complete ✓"
  log "Access Coolify at: http://${TAILSCALE_IP}:8000"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 9 - Coolify install"
```

---

## Task 11: Phase 10 — Traefik security middleware

- [ ] **Step 1: Add phase_10 function**

```bash
phase_10_traefik_hardening() {
  log "Phase 10: Traefik security middleware..."

  TRAEFIK_DYNAMIC_DIR="/data/coolify/proxy/dynamic"
  local retries=0
  while [[ ! -d "$TRAEFIK_DYNAMIC_DIR" && $retries -lt 12 ]]; do
    warn "Waiting for Traefik config dir... (${retries}/12)"
    sleep 10
    ((retries++))
  done

  if [[ ! -d "$TRAEFIK_DYNAMIC_DIR" ]]; then
    warn "Traefik dynamic config dir not found. Re-run script after Coolify starts."
    return 0
  fi

  cat > "$TRAEFIK_DYNAMIC_DIR/security-headers.yml" << 'EOF'
http:
  middlewares:
    security-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        frameDeny: true
        contentTypeNosniff: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=()"
    rate-limit:
      rateLimit:
        average: 100
        burst: 200
        period: 1s
EOF

  log "Phase 10 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 10 - Traefik security headers and rate limiting"
```

---

## Task 12: Phase 11 — auditd (GDPR baseline)

- [ ] **Step 1: Add phase_11 function**

```bash
phase_11_auditd() {
  log "Phase 11: auditd (GDPR baseline)..."
  apt-get install -y auditd audispd-plugins > /dev/null
  systemctl enable auditd

  cat > /etc/audit/rules.d/gdpr.rules << 'EOF'
-w /var/log/auth.log -p wa -k authentication
-w /etc/passwd -p wa -k user-modify
-w /etc/shadow -p wa -k user-modify
-w /etc/group -p wa -k user-modify
-w /etc/sudoers -p wa -k privilege-escalation
-w /etc/sudoers.d/ -p wa -k privilege-escalation
-w /root/.ssh -p wa -k ssh-keys
-w /home -p wa -k ssh-keys
-w /etc/ -p wa -k system-config
-a always,exit -F arch=b64 -S execve -F euid=0 -k root-commands
EOF

  augenrules --load 2>/dev/null || service auditd restart
  log "Phase 11 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 11 - auditd GDPR baseline rules"
```

---

## Task 13: Phase 12 — rclone encrypted backup

- [ ] **Step 1: Add phase_12 function**

```bash
phase_12_backup() {
  log "Phase 12: rclone encrypted backup..."

  if ! command -v rclone &>/dev/null; then
    curl -s https://rclone.org/install.sh | bash > /dev/null
  fi

  mkdir -p /etc/rclone
  cat > /etc/rclone/rclone.conf << EOF
[hetzner]
type = s3
provider = Other
access_key_id = ${HETZNER_ACCESS_KEY}
secret_access_key = ${HETZNER_SECRET_KEY}
endpoint = ${HETZNER_REGION}.your-objectstorage.com
acl = private

[backup]
type = crypt
remote = hetzner:${HETZNER_BUCKET}/backups
filename_encryption = standard
directory_name_encryption = true
password = ${RCLONE_CRYPT_PASS}
password2 = ${RCLONE_CRYPT_PASS2}
EOF
  chmod 600 /etc/rclone/rclone.conf

  cat > /usr/local/bin/backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
DATE=$(date '+%Y-%m-%d')
LOG=/var/log/backup.log
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
log "Starting backup $DATE"

PGCONTAINER=$(docker ps --filter "name=postgres" --format "{{.Names}}" | head -1)
if [[ -n "$PGCONTAINER" ]]; then
  docker exec "$PGCONTAINER" pg_dumpall -U postgres > /tmp/postgres-${DATE}.sql
  rclone --config /etc/rclone/rclone.conf copy /tmp/postgres-${DATE}.sql backup:postgres/
  rm /tmp/postgres-${DATE}.sql
fi

rclone --config /etc/rclone/rclone.conf sync /data/coolify/volumes/minio/ backup:minio/ --log-file="$LOG" 2>&1 || true
rclone --config /etc/rclone/rclone.conf sync /data/coolify/ backup:coolify-config/ --exclude "volumes/**" --log-file="$LOG" 2>&1 || true
log "Backup complete"
EOF
  chmod +x /usr/local/bin/backup.sh

  echo "0 2 * * * root /usr/local/bin/backup.sh" > /etc/cron.d/nightly-backup
  chmod 644 /etc/cron.d/nightly-backup
  log "Phase 12 complete ✓"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 12 - rclone encrypted backup to Hetzner Object Storage"
```

---

## Task 14: Phase 13 — Grafana Alloy

- [ ] **Step 1: Add phase_13 function**

```bash
phase_13_grafana_alloy() {
  log "Phase 13: Grafana Alloy..."

  if ! command -v alloy &>/dev/null; then
    mkdir -p /etc/apt/keyrings/
    wget -q -O /etc/apt/keyrings/grafana.gpg https://apt.grafana.com/gpg.key
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update -q
    apt-get install -y alloy > /dev/null
  fi

  mkdir -p /etc/alloy
  cat > /etc/alloy/config.alloy << EOF
prometheus.exporter.unix "node" { include_exporter_metrics = true }
prometheus.scrape "node" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "${GRAFANA_CLOUD_METRICS_URL}"
    basic_auth { username = "${GRAFANA_CLOUD_USER_ID}"; password = "${GRAFANA_CLOUD_API_KEY}" }
  }
}
prometheus.exporter.cadvisor "docker" { docker_host = "unix:///var/run/docker.sock" }
prometheus.scrape "docker" {
  targets    = prometheus.exporter.cadvisor.docker.targets
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}
loki.source.file "syslog" {
  targets = [
    {__path__ = "/var/log/syslog",    job = "syslog"},
    {__path__ = "/var/log/auth.log",  job = "auth"},
    {__path__ = "/var/log/ufw.log",   job = "ufw"},
    {__path__ = "/var/log/backup.log",job = "backup"},
  ]
  forward_to = [loki.write.grafana_cloud.receiver]
}
discovery.docker "containers" { host = "unix:///var/run/docker.sock" }
loki.source.docker "containers" {
  host    = "unix:///var/run/docker.sock"
  targets = discovery.docker.containers.targets
  forward_to = [loki.write.grafana_cloud.receiver]
  labels  = {job = "docker"}
}
loki.write "grafana_cloud" {
  endpoint {
    url = "${GRAFANA_CLOUD_LOGS_URL}"
    basic_auth { username = "${GRAFANA_CLOUD_USER_ID}"; password = "${GRAFANA_CLOUD_API_KEY}" }
  }
}
EOF

  systemctl enable --now alloy
  log "Phase 13 complete ✓"
  log "Import dashboards: Node Exporter Full (1860), Docker (10619), Loki Logs (13639)"
}
```

- [ ] **Step 2: Wire into main(), verify, commit**

```bash
bash -n setup.sh && echo "OK"
git add setup.sh && git commit -m "feat: phase 13 - Grafana Alloy metrics and logs"
```

---

## Task 15: Phase 14 — lynis + finalize main()

- [ ] **Step 1: Add phase_14 function**

```bash
phase_14_lynis() {
  log "Phase 14: lynis security audit..."

  if ! command -v lynis &>/dev/null; then
    apt-get install -y lynis > /dev/null
  fi

  lynis audit system --quiet --no-colors > /root/lynis-report.txt 2>&1 || true
  SCORE=$(grep "Hardening index" /root/lynis-report.txt | awk '{print $NF}' || echo "n/a")
  log "Hardening index: ${SCORE}/100"
  log "Full report: /root/lynis-report.txt"
  log "Phase 14 complete ✓"
}
```

- [ ] **Step 2: Finalize main() with all 14 phases**

```bash
main() {
  log "Starting Hetzner server setup..."
  notify "🚀 Server setup started on $(hostname)"

  phase_1_user_ssh
  phase_2_private_network
  phase_3_ufw
  phase_4_tailscale
  phase_5_crowdsec
  phase_6_swap
  phase_7_auto_updates
  phase_8_docker
  phase_9_coolify
  phase_10_traefik_hardening
  phase_11_auditd
  phase_12_backup
  phase_13_grafana_alloy
  phase_14_lynis

  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "check tailscale")
  log ""
  log "══════════════════════════════════════════"
  log " Setup complete!"
  log " Coolify:   http://${TAILSCALE_IP}:8000"
  log " MinIO:     http://${TAILSCALE_IP}:9001"
  log " Lynis:     /root/lynis-report.txt"
  log " Backup:    /usr/local/bin/backup.sh"
  log "══════════════════════════════════════════"

  notify "✅ Server setup complete on $(hostname). Coolify: http://${TAILSCALE_IP}:8000"
}
```

- [ ] **Step 3: Final syntax check**

```bash
bash -n setup.sh && echo "PASS: no syntax errors"
```

- [ ] **Step 4: Verify all 14 phases wired**

```bash
grep -c "phase_" setup.sh  # expect ≥28
```

- [ ] **Step 5: Commit**

```bash
git add setup.sh && git commit -m "feat: phase 14 - lynis audit, finalize main() with all phases"
```

---

## Task 16: Smoke test + run on server

- [ ] **Step 1: Syntax check**

```bash
bash -n setup.sh && echo "PASS: no syntax errors"
```

- [ ] **Step 2: Verify all config variables referenced**

```bash
for var in DEPLOY_USER HOME_IP WEBHOOK_URL WEBHOOK_TYPE HETZNER_BUCKET \
           HETZNER_ACCESS_KEY HETZNER_SECRET_KEY HETZNER_REGION \
           RCLONE_CRYPT_PASS RCLONE_CRYPT_PASS2 GRAFANA_CLOUD_METRICS_URL \
           GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_USER_ID GRAFANA_CLOUD_API_KEY \
           TAILSCALE_AUTH_KEY SWAP_SIZE; do
  grep -q "\$$var" setup.sh && echo "OK: $var" || echo "MISSING: $var"
done
```
Expected: all `OK:`

- [ ] **Step 3: Transfer to server**

```bash
# Fill in config block first, then:
scp setup.sh root@<server-ip>:/root/setup.sh
```

- [ ] **Step 4: Run on server**

```bash
ssh root@<server-ip> "bash /root/setup.sh 2>&1 | tee /root/setup.log"
```
Expected: all phases log `✓`, final summary printed, Discord notification received.

- [ ] **Step 5: Post-run verification**

```bash
ssh lxadmin@<tailscale-ip> "
  echo '--- User ---'        && id
  echo '--- UFW ---'         && sudo ufw status
  echo '--- Tailscale ---'   && tailscale status
  echo '--- Swap ---'        && free -h
  echo '--- Docker ---'      && docker info | grep 'no-new-privileges'
  echo '--- Coolify ---'     && sudo systemctl is-active coolify
  echo '--- auditd ---'      && sudo systemctl is-active auditd
  echo '--- Alloy ---'       && sudo systemctl is-active alloy
  echo '--- Backup cron ---' && cat /etc/cron.d/nightly-backup
"
```

---

## Quick Reference — Running on a New Server

```bash
# 1. Fill in config block at top of setup.sh
# 2. Transfer
scp setup.sh root@<new-server-ip>:/root/setup.sh

# 3. Run
ssh root@<new-server-ip> "bash /root/setup.sh 2>&1 | tee /root/setup.log"

# 4. Add to Coolify (in Coolify UI)
#    Servers → Add Server → SSH host: <new-tailscale-ip>
```