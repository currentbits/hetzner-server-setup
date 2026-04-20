#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
# Edit these values before running the script.

DEPLOY_USER="lxadmin"

# Your home public IP — find it at https://ifconfig.me
HOME_IP="x.x.x.x"

# Notification webhook
# Discord: Server Settings → Integrations → Webhooks → New Webhook → Copy URL
# Slack:   api.slack.com → Your Apps → Incoming Webhooks → Add → Copy URL
WEBHOOK_URL="https://discord.com/api/webhooks/..."
WEBHOOK_TYPE="discord"   # "discord" or "slack"

# Hetzner Object Storage
# Console → Object Storage → Buckets → Create Bucket (region: Falkenstein)
# Credentials: Object Storage → Access Keys → Generate Access Key
HETZNER_BUCKET="your-bucket-name"
HETZNER_ACCESS_KEY="..."
HETZNER_SECRET_KEY="..."
HETZNER_REGION="fsn1"   # fsn1=Falkenstein, nbg1=Nuremberg, hel1=Helsinki

# Backup encryption — generate each with: openssl rand -base64 32
RCLONE_CRYPT_PASS="..."
RCLONE_CRYPT_PASS2="..."

# Grafana Cloud
# Cloud → your stack → Connections → Add new connection → Linux node
# Copy the Alloy config: URL, user ID (numeric), and API key
GRAFANA_CLOUD_METRICS_URL="https://prometheus-prod-xx.grafana.net/api/prom/push"
GRAFANA_CLOUD_LOGS_URL="https://logs-prod-xx.grafana.net/loki/api/v1/push"
GRAFANA_CLOUD_USER_ID="123456"
# Grafana Cloud → your profile → Access Policies → Create token
GRAFANA_CLOUD_API_KEY="glc_..."

# Tailscale
# Admin Console → Settings → Keys → Generate auth key (reusable: off)
# https://login.tailscale.com/admin/settings/keys
TAILSCALE_AUTH_KEY="tskey-auth-..."

SWAP_SIZE="4G"

# ──────────────────────────────────────────────────────────────────────────────

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash setup.sh"

# ── Notification helper ────────────────────────────────────────────────────────
notify() {
  local msg="$1"
  if [[ "$WEBHOOK_TYPE" == "slack" ]]; then
    curl -s -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$msg\"}" || true
  else
    curl -s -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"$msg\"}" || true
  fi
}

# ── Phase 1: System user + SSH hardening + login alert ───────────────────────
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
AuthorizedKeysFile .ssh/authorized_keys
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
  curl -s -X POST "\$WEBHOOK_URL" -H "Content-Type: application/json" \
    -d "{\"text\": \"\$MSG\"}" || true
else
  curl -s -X POST "\$WEBHOOK_URL" -H "Content-Type: application/json" \
    -d "{\"content\": \"\$MSG\"}" || true
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

# ── Phase 2: Hetzner Private Network interface ────────────────────────────────
phase_2_private_network() {
  log "Phase 2: Hetzner Private Network interface..."

  if ! ip link show eth1 &>/dev/null; then
    warn "eth1 not found. Attach a Private Network in Hetzner console first. Skipping."
    return 0
  fi

  if ! grep -q "eth1" /etc/network/interfaces 2>/dev/null && \
     [[ ! -f /etc/systemd/network/10-eth1.network ]]; then
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
    log "Configured eth1 with private IP: $PRIVATE_IP"
  else
    log "eth1 already configured, skipping."
  fi

  log "Phase 2 complete ✓"
}

# ── Phase 3: UFW firewall + logging ──────────────────────────────────────────
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
    log "UFW already active, ensuring home IP rule exists..."
    ufw allow from "$HOME_IP" to any port 22 proto tcp comment "SSH home IP" 2>/dev/null || true
  fi

  log "Phase 3 complete ✓"
}

# ── Phase 4: Tailscale ────────────────────────────────────────────────────────
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

# ── Phase 5: CrowdSec ─────────────────────────────────────────────────────────
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
  cscli collections install crowdsecurity/traefik --force 2>/dev/null || true
  cscli collections install crowdsecurity/sshd    --force 2>/dev/null || true

  systemctl enable --now crowdsec
  cscli hub update 2>/dev/null || true

  log "Phase 5 complete ✓"
}

# ── Phase 6: Swap file ────────────────────────────────────────────────────────
phase_6_swap() {
  log "Phase 6: Swap file..."

  if [[ ! -f /swapfile ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Created ${SWAP_SIZE} swap at /swapfile"
  else
    log "Swapfile already exists, skipping."
  fi

  sysctl -w vm.swappiness=10 > /dev/null
  grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf

  log "Phase 6 complete ✓"
}

# ── Phase 7: unattended-upgrades + reboot notifier ───────────────────────────
phase_7_auto_updates() {
  log "Phase 7: Automatic updates + reboot notifier..."

  apt-get install -y unattended-upgrades apt-listchanges > /dev/null

  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}";
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
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

# ── Phase 8: Docker CE + hardened daemon.json ─────────────────────────────────
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
    apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin > /dev/null
  fi

  usermod -aG docker "$DEPLOY_USER"

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << 'EOF'
{
  "no-new-privileges": true,
  "live-restore": true,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
EOF

  systemctl enable docker
  systemctl restart docker

  log "Phase 8 complete ✓"
}

# ── Phase 9: Coolify ──────────────────────────────────────────────────────────
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

# ── Phase 10: Traefik global security middleware ──────────────────────────────
phase_10_traefik_hardening() {
  log "Phase 10: Traefik security middleware..."

  TRAEFIK_DYNAMIC_DIR="/data/coolify/proxy/dynamic"
  local retries=0
  while [[ ! -d "$TRAEFIK_DYNAMIC_DIR" && $retries -lt 12 ]]; do
    warn "Waiting for Traefik config dir ($TRAEFIK_DYNAMIC_DIR)... (${retries}/12)"
    sleep 10
    ((retries++))
  done

  if [[ ! -d "$TRAEFIK_DYNAMIC_DIR" ]]; then
    warn "Traefik dynamic config dir not found. Coolify may still be starting."
    warn "After Coolify is running, re-run: bash setup.sh (idempotent — safe to re-run)"
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
  log "Apply to apps in Coolify with label:"
  log "  traefik.http.routers.<app>.middlewares=security-headers@file,rate-limit@file"
}

# ── Phase 11: auditd (GDPR baseline) ─────────────────────────────────────────
phase_11_auditd() {
  log "Phase 11: auditd (GDPR baseline)..."

  apt-get install -y auditd audispd-plugins > /dev/null
  systemctl enable auditd

  cat > /etc/audit/rules.d/gdpr.rules << 'EOF'
# Authentication events
-w /var/log/auth.log -p wa -k authentication
-w /etc/passwd -p wa -k user-modify
-w /etc/shadow -p wa -k user-modify
-w /etc/group -p wa -k user-modify
-w /etc/sudoers -p wa -k privilege-escalation
-w /etc/sudoers.d/ -p wa -k privilege-escalation

# SSH key changes
-w /root/.ssh -p wa -k ssh-keys
-w /home -p wa -k ssh-keys

# System config changes
-w /etc/ -p wa -k system-config

# Privileged commands
-a always,exit -F arch=b64 -S execve -F euid=0 -k root-commands
EOF

  augenrules --load 2>/dev/null || service auditd restart

  log "Phase 11 complete ✓"
}

# ── Phase 12: rclone + encrypted backup ──────────────────────────────────────
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
  log "Postgres backup done"
fi

rclone --config /etc/rclone/rclone.conf sync \
  /data/coolify/volumes/minio/ backup:minio/ \
  --log-file="$LOG" 2>&1 || true

rclone --config /etc/rclone/rclone.conf sync \
  /data/coolify/ backup:coolify-config/ \
  --exclude "volumes/**" \
  --log-file="$LOG" 2>&1 || true

log "Backup complete"
EOF
  chmod +x /usr/local/bin/backup.sh

  echo "0 2 * * * root /usr/local/bin/backup.sh" > /etc/cron.d/nightly-backup
  chmod 644 /etc/cron.d/nightly-backup

  log "Phase 12 complete ✓"
  log "Test backup manually: /usr/local/bin/backup.sh"
}

# ── Phase 13: Grafana Alloy ───────────────────────────────────────────────────
phase_13_grafana_alloy() {
  log "Phase 13: Grafana Alloy..."

  if ! command -v alloy &>/dev/null; then
    mkdir -p /etc/apt/keyrings/
    wget -q -O /etc/apt/keyrings/grafana.gpg \
      https://apt.grafana.com/gpg.key
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] \
      https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update -q
    apt-get install -y alloy > /dev/null
  fi

  mkdir -p /etc/alloy

  cat > /etc/alloy/config.alloy << EOF
// ── System metrics → Grafana Cloud ────────────────────────────────────────
prometheus.exporter.unix "node" {
  include_exporter_metrics = true
}

prometheus.scrape "node" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}

prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "${GRAFANA_CLOUD_METRICS_URL}"
    basic_auth {
      username = "${GRAFANA_CLOUD_USER_ID}"
      password = "${GRAFANA_CLOUD_API_KEY}"
    }
  }
}

// ── Docker container metrics ───────────────────────────────────────────────
prometheus.exporter.cadvisor "docker" {
  docker_host = "unix:///var/run/docker.sock"
}

prometheus.scrape "docker" {
  targets    = prometheus.exporter.cadvisor.docker.targets
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}

// ── Logs → Grafana Cloud Loki ──────────────────────────────────────────────
loki.source.file "system_logs" {
  targets = [
    {__path__ = "/var/log/syslog",    job = "syslog"},
    {__path__ = "/var/log/auth.log",  job = "auth"},
    {__path__ = "/var/log/ufw.log",   job = "ufw"},
    {__path__ = "/var/log/backup.log",job = "backup"},
  ]
  forward_to = [loki.write.grafana_cloud.receiver]
}

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

loki.source.docker "containers" {
  host    = "unix:///var/run/docker.sock"
  targets = discovery.docker.containers.targets
  forward_to = [loki.write.grafana_cloud.receiver]
  labels  = {job = "docker"}
}

loki.write "grafana_cloud" {
  endpoint {
    url = "${GRAFANA_CLOUD_LOGS_URL}"
    basic_auth {
      username = "${GRAFANA_CLOUD_USER_ID}"
      password = "${GRAFANA_CLOUD_API_KEY}"
    }
  }
}
EOF

  systemctl enable --now alloy

  log "Phase 13 complete ✓"
  log "Import Grafana dashboards:"
  log "  Node Exporter Full : ID 1860"
  log "  Docker metrics     : ID 10619"
  log "  Loki logs          : ID 13639"
}

# ── Phase 14: lynis security audit ───────────────────────────────────────────
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

# ── Main ──────────────────────────────────────────────────────────────────────
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

  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "check-tailscale-ip")

  log ""
  log "══════════════════════════════════════════════"
  log " Setup complete!"
  log " Coolify : http://${TAILSCALE_IP}:8000"
  log " MinIO   : http://${TAILSCALE_IP}:9001"
  log " Lynis   : /root/lynis-report.txt"
  log " Backup  : /usr/local/bin/backup.sh"
  log "══════════════════════════════════════════════"

  notify "✅ Server setup complete on $(hostname). Coolify: http://${TAILSCALE_IP}:8000"
}

main
