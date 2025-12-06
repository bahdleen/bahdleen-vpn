#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="bahdleen-vpn.sh"
APP_NAME="bahdleen-vpn"
LIB_DIR="/usr/local/lib/bahdleen-vpn"
BIN_PATH="/usr/local/bin/${APP_NAME}"
SCRIPT_PATH="${LIB_DIR}/${SCRIPT_NAME}"

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Please run install with sudo:"
  echo "        sudo ./install.sh"
  exit 1
fi

echo "[INFO] Installing ${APP_NAME}..."

mkdir -p "$LIB_DIR"
install -m 0755 "$SCRIPT_NAME" "$SCRIPT_PATH"

cat > "$BIN_PATH" <<EOF
#!/usr/bin/env bash
exec sudo -n ${SCRIPT_PATH} "\$@"
EOF
chmod +x "$BIN_PATH"

echo "[OK] Installed:"
echo "  Script  -> $SCRIPT_PATH"
echo "  Command -> $BIN_PATH"

# Optional restricted sudoers rule
SUDOERS_FILE="/etc/sudoers.d/${APP_NAME}"
cat > "$SUDOERS_FILE" <<EOF
# Allow passwordless sudo ONLY for Bahdleen VPN script
ALL ALL=(root) NOPASSWD: ${SCRIPT_PATH}
EOF
chmod 440 "$SUDOERS_FILE"

echo "[OK] Restricted sudo rule created at ${SUDOERS_FILE}"

echo
echo "[DONE] You can now run:"
echo "  ${APP_NAME}"
