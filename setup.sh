#!/bin/bash
set -e

cd "$(dirname "$0")"

if [ ! -f compose.yml.template ]; then
  echo "ERROR: compose.yml.template not found."
  exit 1
fi
if [ ! -f garage.toml.template ]; then
  echo "ERROR: garage.toml.template not found."
  exit 1
fi

# ── Configuration ────────────────────────────────────────────────────

SERVER_IP="${SERVER_IP:-}"
if [ -z "$SERVER_IP" ]; then
  # Try to auto-detect LAN IP
  DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ip route get 1 2>/dev/null | awk '{print $7; exit}' || echo "")
  if [ -n "$DETECTED_IP" ]; then
    read -p "Server IP [$DETECTED_IP]: " INPUT_IP
    SERVER_IP="${INPUT_IP:-$DETECTED_IP}"
  else
    read -p "Server IP (e.g. 192.168.1.100): " SERVER_IP
  fi
fi

if [ -z "$SERVER_IP" ]; then
  echo "ERROR: Server IP is required."
  exit 1
fi
echo "Using server IP: $SERVER_IP"

# ── Generate secrets ─────────────────────────────────────────────────

echo ""
echo "=== Step 1: Generating secrets ==="
JWT_SECRET=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
KEY_ENCRYPTION=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
GARAGE_RPC_SECRET=$(openssl rand -hex 32)
GARAGE_ADMIN_TOKEN=$(openssl rand -hex 32)

echo "  JWT secret:        ${JWT_SECRET:0:12}..."
echo "  Encryption key:    ${KEY_ENCRYPTION:0:12}..."
echo "  Garage RPC secret: ${GARAGE_RPC_SECRET:0:12}..."
echo "  Garage admin token:${GARAGE_ADMIN_TOKEN:0:12}..."

# ── Generate config files from templates ─────────────────────────────

echo ""
echo "=== Step 2: Generating config files ==="

python3 -c "
import sys
replacements = dict(pair.split('=', 1) for pair in sys.argv[1:])
for src, dst in [('compose.yml.template', 'compose.yml'), ('garage.toml.template', 'garage.toml')]:
    text = open(src).read()
    for key, val in replacements.items():
        text = text.replace(key, val)
    open(dst, 'w').write(text)
" \
  "__SERVER_IP__=$SERVER_IP" \
  "__JWT_SECRET__=$JWT_SECRET" \
  "__KEY_ENCRYPTION__=$KEY_ENCRYPTION" \
  "__GARAGE_RPC_SECRET__=$GARAGE_RPC_SECRET" \
  "__GARAGE_ADMIN_TOKEN__=$GARAGE_ADMIN_TOKEN"

echo "  compose.yml generated."
echo "  garage.toml generated."

# ── Start infrastructure ─────────────────────────────────────────────

echo ""
echo "=== Step 3: Starting postgres + garage ==="
docker compose up -d postgres garage
echo "Waiting for services to be healthy..."
sleep 5

# ── Run garage-init ──────────────────────────────────────────────────

echo ""
echo "=== Step 4: Running garage-init ==="
set +e
INIT_OUTPUT=$(docker compose --profile init run --rm garage-init 2>&1)
INIT_EXIT=$?
set -e
echo "$INIT_OUTPUT"

if [ $INIT_EXIT -ne 0 ]; then
  echo "ERROR: garage-init exited with code $INIT_EXIT"
  echo "Check the output above for errors."
  exit 1
fi

# Extract Garage API credentials from init output
KEY_ID=$(echo "$INIT_OUTPUT" | grep '^GARAGE_KEY_ID=' | cut -d= -f2)
KEY_SECRET=$(echo "$INIT_OUTPUT" | grep '^GARAGE_KEY_SECRET=' | cut -d= -f2)

if [ -z "$KEY_ID" ] || [ -z "$KEY_SECRET" ]; then
  echo "ERROR: Failed to extract Garage credentials from init output."
  echo "Check the output above for errors."
  exit 1
fi

echo ""
echo "Garage Key ID:     $KEY_ID"
echo "Garage Key Secret: ${KEY_SECRET:0:12}..."

# ── Patch compose.yml with Garage credentials ────────────────────────

echo ""
echo "=== Step 5: Patching compose.yml with Garage credentials ==="
python3 -c "
import sys
text = open('compose.yml').read()
text = text.replace('__GARAGE_KEY_ID__', sys.argv[1])
text = text.replace('__GARAGE_KEY_SECRET__', sys.argv[2])
open('compose.yml', 'w').write(text)
" "$KEY_ID" "$KEY_SECRET"
echo "compose.yml patched."

# ── Start all services ───────────────────────────────────────────────

echo ""
echo "=== Step 6: Starting all services ==="
docker compose up -d
echo ""

echo "=== Setup complete! ==="
echo ""
echo "Verification:"
echo "  API:  curl http://$SERVER_IP:8081/ping"
echo "  Web:  http://$SERVER_IP:3000"
echo ""
echo "First login:"
echo "  Sign up with any @example.org email, OTP: 123456"
echo ""
echo "After signing up, remove the 10 GB storage limit:"
echo "  docker compose exec -T postgres psql -U pguser ente_db < storage-fix.sql"
echo ""
echo "Mobile apps:"
echo "  Tap 7 times on login screen -> enter http://$SERVER_IP:8081"
