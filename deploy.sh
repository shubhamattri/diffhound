#!/bin/bash
# deploy.sh — Deploy diffhound webhook server on nova-dev-shubham
#
# Usage:
#   ssh nova-dev-shubham
#   cd ~/diffhound && bash deploy.sh
#
# Prerequisites:
#   - gh auth login (with repo, pull_request scopes)
#   - claude CLI installed and authenticated
#   - WEBHOOK_SECRET set in the service file

set -euo pipefail

echo "=== Diffhound Webhook Deployment ==="

# ── 1. System dependencies ───────────────────────────────────
echo "[1/6] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq jq python3 python3-pip git > /dev/null 2>&1
pip3 install --quiet flask gunicorn

# ── 2. Clone monorepo (if not already present) ──────────────
MONOREPO_PATH="${HOME}/monorepo"
if [ ! -d "$MONOREPO_PATH/.git" ]; then
    echo "[2/6] Cloning monorepo..."
    git clone https://github.com/novabenefits/monorepo.git "$MONOREPO_PATH"
else
    echo "[2/6] Monorepo already cloned, syncing..."
    git -C "$MONOREPO_PATH" fetch origin
    git -C "$MONOREPO_PATH" checkout origin/master -f
fi

# ── 3. Verify diffhound is ready ────────────────────────────
echo "[3/6] Verifying diffhound..."
DIFFHOUND_BIN="${HOME}/diffhound/bin/diffhound"
if [ ! -x "$DIFFHOUND_BIN" ]; then
    echo "ERROR: $DIFFHOUND_BIN not found or not executable"
    echo "Clone diffhound to ~/diffhound first:"
    echo "  git clone https://github.com/shubhamattri/diffhound.git ~/diffhound"
    exit 1
fi

# Verify dependencies
for cmd in gh claude jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: $cmd not found in PATH"
        exit 1
    fi
done
echo "  diffhound binary: OK"
echo "  gh cli: OK"
echo "  claude cli: OK"

# ── 4. Create log directory ──────────────────────────────────
echo "[4/6] Setting up directories..."
mkdir -p "${HOME}/logs/pr-reviews"

# ── 5. Install systemd service ───────────────────────────────
echo "[5/6] Installing systemd service..."
SERVICE_FILE="${HOME}/diffhound/lib/diffhound-webhook.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "ERROR: $SERVICE_FILE not found"
    exit 1
fi

# Check if WEBHOOK_SECRET has been configured
if grep -q 'CHANGEME' "$SERVICE_FILE"; then
    echo ""
    echo "WARNING: WEBHOOK_SECRET is still set to CHANGEME in the service file."
    echo "Edit $SERVICE_FILE and set the real secret before continuing."
    echo ""
    read -rp "Continue anyway? (y/N) " confirm
    [ "$confirm" != "y" ] && exit 1
fi

sudo cp "$SERVICE_FILE" /etc/systemd/system/diffhound-webhook.service
sudo systemctl daemon-reload
sudo systemctl enable diffhound-webhook
sudo systemctl restart diffhound-webhook

echo "  Service installed and started"

# ── 6. Set up repo sync cron (every 5 min) ──────────────────
echo "[6/6] Setting up repo sync cron..."
CRON_CMD="*/5 * * * * cd ${MONOREPO_PATH} && git fetch --all --quiet && git checkout origin/master -f --quiet 2>/dev/null"
(crontab -l 2>/dev/null | grep -v "monorepo.*git fetch" ; echo "$CRON_CMD") | crontab -

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Verify:"
echo "  sudo systemctl status diffhound-webhook"
echo "  curl http://localhost:8090/health"
echo ""
echo "Logs:"
echo "  journalctl -u diffhound-webhook -f"
echo "  tail -f ~/logs/pr-reviews/webhook.log"
echo ""
echo "Next steps:"
echo "  1. Set WEBHOOK_SECRET in /etc/systemd/system/diffhound-webhook.service"
echo "  2. Add GCP firewall rule: gcloud compute firewall-rules create diffhound-webhook \\"
echo "       --allow tcp:8090 --source-ranges 140.82.112.0/20,185.199.108.0/22,192.30.252.0/22 \\"
echo "       --target-tags diffhound-webhook"
echo "  3. Add network tag 'diffhound-webhook' to the VM"
echo "  4. Configure GitHub webhook: http://34.100.159.99:8090/webhook"
