#!/usr/bin/env bash
# ============================================================================
# DevskinCloud CLI Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/devskin1/cloud-devskin-cli/main/install.sh | bash
# ============================================================================

set -euo pipefail

INSTALL_DIR="${DEVSKIN_INSTALL_DIR:-/usr/local/bin}"
CLI_URL="${DEVSKIN_CLI_URL:-https://raw.githubusercontent.com/devskin1/cloud-devskin-cli/main/devskin-cli.sh}"
BINARY_NAME="devskin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo ""
echo -e "${BOLD}  DevskinCloud CLI Installer${NC}"
echo -e "  =========================="
echo ""

# ------------------------------------------------------------------
# 1. Platform checks
# ------------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Linux|Darwin) ;;
  *)
    _error "Unsupported operating system: $OS"
    exit 1
    ;;
esac

# Require curl or wget
if command -v curl &>/dev/null; then
  DOWNLOADER="curl"
elif command -v wget &>/dev/null; then
  DOWNLOADER="wget"
else
  _error "Neither curl nor wget found. Please install one and retry."
  exit 1
fi

# Require jq (optional but recommended)
if ! command -v jq &>/dev/null; then
  _warn "jq is not installed. The CLI will fall back to python for JSON parsing."
  _warn "For the best experience, install jq:"
  if [[ "$OS" == "Linux" ]]; then
    _warn "  sudo apt-get install jq   # Debian/Ubuntu"
    _warn "  sudo yum install jq       # RHEL/CentOS"
  else
    _warn "  brew install jq           # macOS"
  fi
  echo ""
fi

# ------------------------------------------------------------------
# 2. Download
# ------------------------------------------------------------------
TEMP_FILE="$(mktemp /tmp/devskin-cli.XXXXXX)"
trap 'rm -f "$TEMP_FILE"' EXIT

_info "Downloading DevskinCloud CLI from $CLI_URL ..."
if [[ "$DOWNLOADER" == "curl" ]]; then
  curl -fsSL "$CLI_URL" -o "$TEMP_FILE"
else
  wget -q "$CLI_URL" -O "$TEMP_FILE"
fi
_ok "Download complete."

# Sanity check - make sure we got a valid bash script
if ! head -1 "$TEMP_FILE" | grep -q '#!/usr/bin/env bash'; then
  _error "Downloaded file does not look like a valid CLI script."
  exit 1
fi

# ------------------------------------------------------------------
# 3. Install
# ------------------------------------------------------------------
_info "Installing to ${INSTALL_DIR}/${BINARY_NAME} ..."

NEEDS_SUDO=false
if [[ ! -w "$INSTALL_DIR" ]]; then
  NEEDS_SUDO=true
fi

if $NEEDS_SUDO; then
  if ! command -v sudo &>/dev/null; then
    _error "Cannot write to ${INSTALL_DIR} and sudo is not available."
    _error "Run this script as root or set DEVSKIN_INSTALL_DIR to a writable directory."
    exit 1
  fi
  sudo mkdir -p "$INSTALL_DIR"
  sudo mv "$TEMP_FILE" "${INSTALL_DIR}/${BINARY_NAME}"
  sudo chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
else
  mkdir -p "$INSTALL_DIR"
  mv "$TEMP_FILE" "${INSTALL_DIR}/${BINARY_NAME}"
  chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
fi

_ok "Installed ${INSTALL_DIR}/${BINARY_NAME}"

# ------------------------------------------------------------------
# 4. Create config directory
# ------------------------------------------------------------------
CONFIG_DIR="$HOME/.devskin"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
_ok "Config directory ready: ${CONFIG_DIR}"

# ------------------------------------------------------------------
# 5. Verify PATH
# ------------------------------------------------------------------
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  _warn "${INSTALL_DIR} is not in your PATH."
  _warn "Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
  _warn "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  echo ""
fi

# ------------------------------------------------------------------
# 6. Done
# ------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}  DevskinCloud CLI installed successfully!${NC}"
echo ""
echo "  Get started:"
echo "    devskin configure       # Set your API URL and token"
echo "    devskin login           # Or authenticate with email/password"
echo "    devskin --help          # View all available commands"
echo ""
