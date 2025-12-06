#!/usr/bin/env bash
set -euo pipefail

APP_NAME="bahdleen-vpn"
LIB_DIR="/usr/local/lib/bahdleen-vpn"
BIN_PATH="/usr/local/bin/${APP_NAME}"
SUDOERS_FILE="/etc/sudoers.d/${APP_NAME}"

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Please run uninstall with sudo:"
  echo "        sudo ./uninstall.sh"
  exit 1
fi

echo "[INFO] Removing ${APP_NAME}..."

rm -f "$BIN_PATH"
rm -rf "$LIB_DIR"
rm -f "$SUDOERS_FILE"

echo "[OK] Removed:"
echo "  $BIN_PATH"
echo "  $LIB_DIR"
echo "  $SUDOERS_FILE"

echo "[DONE]"
