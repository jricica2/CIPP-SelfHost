#!/usr/bin/env bash
# =============================================================================
# CIPP Self-Hosted Setup Script (Linux/macOS)
# =============================================================================
# Interactive setup that generates the .env file, builds the frontend,
# and optionally starts the Docker containers.
#
# Usage:
#   ./setup.sh              # Interactive mode (prompts for all values)
#   ./setup.sh -s           # Interactive mode + auto-start containers
#   ./setup.sh --skip-build # Skip frontend build step
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_CONTAINERS=false
SKIP_BUILD=false

# Parse flags
for arg in "$@"; do
  case $arg in
    -s|--start) START_CONTAINERS=true ;;
    --skip-build) SKIP_BUILD=true ;;
    -h|--help)
      echo "Usage: $0 [-s|--start] [--skip-build]"
      echo "  -s, --start      Start Docker containers after setup"
      echo "  --skip-build     Skip the frontend build step"
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
prompt_value() {
  local prompt="$1"
  local default="${2:-}"
  local is_secret="${3:-false}"
  local value=""

  if [ -n "$default" ]; then
    prompt="$prompt [$default]"
  fi

  if [ "$is_secret" = "true" ]; then
    read -s -p "$prompt: " value
    echo ""
  else
    read -p "$prompt: " value
  fi

  if [ -z "$value" ]; then
    value="$default"
  fi

  echo "$value"
}

prompt_required() {
  local prompt="$1"
  local default="${2:-}"
  local is_secret="${3:-false}"
  local value=""

  while true; do
    value="$(prompt_value "$prompt" "$default" "$is_secret")"
    if [ -n "$value" ]; then
      echo "$value"
      return
    fi
    echo "  ERROR: This value is required." >&2
  done
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  CIPP Self-Hosted Setup"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo "[1/6] Checking prerequisites..."

# Docker
if command -v docker &> /dev/null; then
  echo "  OK - Docker found ($(docker --version 2>/dev/null | head -1))"
else
  echo "  ERROR - Docker is not installed"
  echo "  Install: https://docs.docker.com/engine/install/ubuntu/"
  exit 1
fi

# Docker Compose (v2)
if docker compose version &> /dev/null; then
  echo "  OK - Docker Compose v2 found"
else
  echo "  ERROR - Docker Compose v2 not found"
  echo "  Install Docker Engine which includes Compose v2"
  exit 1
fi

# Node.js
if command -v node &> /dev/null; then
  echo "  OK - Node.js found ($(node --version 2>/dev/null))"
else
  echo "  ERROR - Node.js is not installed"
  echo "  Install Node.js 22 LTS: https://nodejs.org/"
  exit 1
fi

# CIPP frontend repo
CIPP_FRONTEND_DIR="$SCRIPT_DIR/../CIPP"
if [ -f "$CIPP_FRONTEND_DIR/package.json" ]; then
  echo "  OK - CIPP frontend repo found"
else
  echo "  ERROR - CIPP frontend repo not found at: $CIPP_FRONTEND_DIR"
  echo "  Clone your CIPP fork as a sibling directory to CIPP-SelfHost:"
  echo "    git clone https://github.com/jricica2/CIPP.git ../CIPP"
  exit 1
fi

# CIPP-API repo
CIPP_API_DIR="$SCRIPT_DIR/../CIPP-API"
if [ -f "$CIPP_API_DIR/Dockerfile" ]; then
  echo "  OK - CIPP-API repo found"
else
  echo "  ERROR - CIPP-API repo not found at: $CIPP_API_DIR"
  echo "  Clone your CIPP-API fork as a sibling directory to CIPP-SelfHost:"
  echo "    git clone https://github.com/jricica2/CIPP-API.git ../CIPP-API"
  exit 1
fi

# ---------------------------------------------------------------------------
# Collect configuration
# ---------------------------------------------------------------------------
echo ""
echo "[2/6] SAM Application Credentials"
echo "  These come from your CIPP SAM app registration."
echo "  (The app that accesses Microsoft Graph on your tenant)"
echo ""

SAM_APP_ID="$(prompt_required "SAM Application (Client) ID")"
SAM_APP_SECRET="$(prompt_required "SAM Application Secret" "" "true")"
SAM_TENANT_ID="$(prompt_required "SAM Tenant ID")"
SAM_REFRESH_TOKEN="$(prompt_required "SAM Refresh Token" "" "true")"

echo ""
echo "[3/6] Portal Login App Registration"
echo "  Create a NEW app registration in Entra ID for portal login."
echo "  Type: Web, Single tenant"
echo "  Permissions: openid, profile, email (delegated)"
echo ""

PORTAL_TENANT_ID="$(prompt_required "Portal Tenant ID" "$SAM_TENANT_ID")"
PORTAL_CLIENT_ID="$(prompt_required "Portal App Client ID")"
PORTAL_CLIENT_SECRET="$(prompt_required "Portal App Client Secret" "" "true")"

echo ""
echo "[4/6] General Configuration"
echo ""

HOSTNAME="$(prompt_required "Hostname for CIPP access (e.g., cipp.example.com, 192.168.1.100)" "localhost")"
ADMIN_UPN="$(prompt_required "Initial admin email/UPN (e.g., admin@contoso.com)")"

# Generate session secret
SESSION_SECRET="$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"

# Reminder about redirect URI
echo ""
echo "  IMPORTANT: Ensure your Portal app registration has this redirect URI:"
echo "  https://$HOSTNAME/auth/callback"
echo ""

# ---------------------------------------------------------------------------
# Write .env file
# ---------------------------------------------------------------------------
echo "[5/6] Writing .env file..."

ENV_PATH="$SCRIPT_DIR/.env"
cat > "$ENV_PATH" <<EOF
# CIPP Self-Host Configuration
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')

# SAM Credentials
SAM_APPLICATION_ID=$SAM_APP_ID
SAM_APPLICATION_SECRET=$SAM_APP_SECRET
SAM_TENANT_ID=$SAM_TENANT_ID
SAM_REFRESH_TOKEN=$SAM_REFRESH_TOKEN

# Portal Login App
PORTAL_TENANT_ID=$PORTAL_TENANT_ID
PORTAL_CLIENT_ID=$PORTAL_CLIENT_ID
PORTAL_CLIENT_SECRET=$PORTAL_CLIENT_SECRET

# General Config
CIPP_HOSTNAME=$HOSTNAME
SESSION_SECRET=$SESSION_SECRET
DEFAULT_ADMIN_UPN=$ADMIN_UPN
EOF

chmod 600 "$ENV_PATH"
echo "  OK - .env written to $ENV_PATH (permissions: 600)"

# ---------------------------------------------------------------------------
# Build frontend
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "[6/6] Building CIPP frontend..."
  echo "  This may take a few minutes on first run."

  cd "$CIPP_FRONTEND_DIR"
  echo "  Installing dependencies..."
  npm install --silent 2>&1
  echo "  Running build..."
  npx next build 2>&1
  cd "$SCRIPT_DIR"

  if [ -f "$CIPP_FRONTEND_DIR/out/index.html" ]; then
    echo "  OK - Frontend built to $CIPP_FRONTEND_DIR/out/"
  else
    echo "  WARNING - Frontend build may have failed. Check for errors above."
    echo "  You can retry manually: cd $CIPP_FRONTEND_DIR && npm install && npx next build"
  fi
else
  echo ""
  echo "[6/6] Skipping frontend build (--skip-build)"
  if [ ! -f "$CIPP_FRONTEND_DIR/out/index.html" ]; then
    echo "  WARNING - Frontend output not found at $CIPP_FRONTEND_DIR/out/"
    echo "  Run: cd $CIPP_FRONTEND_DIR && npm install && npx next build"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Setup Complete"
echo "========================================"
echo ""
echo "To start CIPP:"
echo "  cd $SCRIPT_DIR"
echo "  docker compose up -d"
echo ""
echo "Then configure your reverse proxy (Pangolin, etc.) to target port 3000."
echo "Open: https://$HOSTNAME"
echo ""
echo "To view logs:"
echo "  docker compose logs -f"
echo ""
echo "To stop:"
echo "  docker compose down"
echo ""

if [ "$START_CONTAINERS" = true ]; then
  echo "Starting containers..."
  cd "$SCRIPT_DIR"
  docker compose up -d
  echo ""
  echo "Containers starting. Wait ~60 seconds for initial setup."
  echo "Then configure Pangolin to target port 3000 and open: https://$HOSTNAME"
fi
