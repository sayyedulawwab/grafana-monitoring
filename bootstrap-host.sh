#!/usr/bin/env bash
# One-time host preparation for the Ubuntu monitoring VM.
# Run ONCE, manually, as root. After this the release pipeline never needs sudo.
#
#   sudo AGENT_USER=<agent-user> WIN_SERVER=<app-server-ip> DESKTOP_CIDR=<lan-cidr> bash bootstrap-host.sh
#
set -euo pipefail

AGENT_USER="${AGENT_USER:?set AGENT_USER to the Linux user the Azure DevOps agent runs as}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/monitoring}"
WIN_SERVER="${WIN_SERVER:?set WIN_SERVER to the IP of the server that sends OTLP}"
DESKTOP_CIDR="${DESKTOP_CIDR:?set DESKTOP_CIDR to the LAN range allowed to open Grafana}"

echo "==> Creating $DEPLOY_ROOT owned by $AGENT_USER"
mkdir -p "$DEPLOY_ROOT"
chown "$AGENT_USER:$AGENT_USER" "$DEPLOY_ROOT"

echo "==> Creating persistent data directories with the container UIDs"
# These UIDs are baked into the upstream images. Getting them wrong is the
# single most common cause of permission-denied crash loops on first start.
# The pipeline excludes these paths from rsync, so deploys never touch them.
mkdir -p "$DEPLOY_ROOT/loki/data"
mkdir -p "$DEPLOY_ROOT/tempo/data"
mkdir -p "$DEPLOY_ROOT/prometheus/data"
mkdir -p "$DEPLOY_ROOT/grafana/data"

chown -R 10001:10001 "$DEPLOY_ROOT/loki/data"       # loki
chown -R 10001:10001 "$DEPLOY_ROOT/tempo/data"      # tempo
chown -R 65534:65534 "$DEPLOY_ROOT/prometheus/data" # nobody
chown -R 472:472     "$DEPLOY_ROOT/grafana/data"    # grafana

echo "==> Adding $AGENT_USER to the docker group"
usermod -aG docker "$AGENT_USER"

echo "==> Ensuring Docker starts on boot"
systemctl enable --now docker

echo "==> Firewall rules"
ufw allow from "$WIN_SERVER"   to any port 14318 proto tcp comment 'OTLP HTTP from Windows Server'
ufw allow from "$DESKTOP_CIDR" to any port 3000  proto tcp comment 'Grafana from LAN'
ufw status numbered

cat <<MSG

==> Done.

Remaining manual steps:
  1. Restart the Azure DevOps agent so it picks up the docker group membership:
       sudo systemctl restart 'vsts.agent.*'
  2. Confirm the agent user can reach Docker without sudo:
       sudo -u $AGENT_USER docker ps
  3. Confirm the agent is enabled at boot:
       systemctl is-enabled 'vsts.agent.*'

MSG