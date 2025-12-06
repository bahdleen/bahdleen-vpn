#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
#  Bahdleen VPN Manager (OpenVPN + WireGuard)
#
#  Supported distros:
#   - Ubuntu, Debian, Linux Mint
#   - Fedora
#   - Arch, Manjaro
#   - openSUSE
#
#  Client exports (IN HOME of invoking user):
#   - ~/ovpn-clients
#   - ~/wireguard-clients
#
#  Production-grade behaviors:
#   - Auto-detect OS
#   - Debian preflight disables broken OpenVPN3 repo
#   - Ensures CA certs before APT runs
#   - Multi-method public IP detection (HTTPS + DNS)
#   - Clear messaging when provider blocks detection
#   - Persistent NAT via systemd + iptables-restore
#
#  Global command:
#   - Install via menu (guaranteed installer)
#   - After install: run "bahdleen-vpn" anytime
# =========================================================

# -------------------- UI --------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m $*"; }

banner() {
  clear
  cat <<'EOF'
██████╗  █████╗ ██╗  ██╗██████╗ ██╗     ███████╗███████╗███╗   ██╗
██╔══██╗██╔══██╗██║  ██║██╔══██╗██║     ██╔════╝██╔════╝████╗  ██║
██████╔╝███████║███████║██║  ██║██║     █████╗  █████╗  ██╔██╗ ██║
██╔══██╗██╔══██║██╔══██║██║  ██║██║     ██╔══╝  ██╔══╝  ██║╚██╗██║
██████╔╝██║  ██║██║  ██║██████╔╝███████╗███████╗███████╗██║ ╚████║
╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚══════╝╚══════╝╚═╝  ╚═══╝

                 B A H D L E E N   -   V P N
EOF
  echo
}

safe_read() {
  local prompt="$1"
  local __var="$2"
  local input=""
  if ! read -r -p "${prompt}" input; then
    err "Input cancelled."
    return 1
  fi
  printf -v "${__var}" "%s" "${input}"
  return 0
}

pause() {
  local _t=""
  safe_read "Press Enter to continue..." _t || true
}

# -------------------- Real user / home --------------------
get_real_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  else
    echo "$(logname 2>/dev/null || echo "${USER}")"
  fi
}

get_real_home() {
  local u
  u="$(get_real_user)"
  getent passwd "$u" | awk -F: '{print $6}'
}

REAL_USER="$(get_real_user)"
REAL_HOME="$(get_real_home)"
if [[ -z "${REAL_HOME}" || ! -d "${REAL_HOME}" ]]; then
  REAL_HOME="/home/${REAL_USER}"
fi

# -------------------- Client export dirs --------------------
OVPN_CLIENT_OUT="${REAL_HOME}/ovpn-clients"
WG_CLIENT_OUT="${REAL_HOME}/wireguard-clients"

# -------------------- Bahdleen state (user-scoped) --------------------
STATE_DIR="${REAL_HOME}/.bahdleen-vpn"
STATE_FILE="${STATE_DIR}/state.env"

# -------------------- System paths --------------------
OVPN_DIR="/etc/openvpn"
OVPN_SERVER_DIR="${OVPN_DIR}/server"
EASYRSA_DIR="${OVPN_DIR}/easy-rsa"
PKI_DIR="${EASYRSA_DIR}/pki"
OVPN_SERVER_CONF="${OVPN_SERVER_DIR}/server.conf"
OVPN_TLS_KEY="${OVPN_SERVER_DIR}/ta.key"

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
WG_PEERS_DB="${WG_DIR}/peers.db"
WG_SERVER_PRIV="${WG_DIR}/server_private.key"
WG_SERVER_PUB="${WG_DIR}/server_public.key"

SYSCTL_FILE="/etc/sysctl.d/99-bahdleen-vpn.conf"
NAT_RULES_FILE="/etc/bahdleen-vpn-iptables.rules"
NAT_UNIT="/etc/systemd/system/bahdleen-vpn-nat.service"
OVPN_UNIT="/etc/systemd/system/bahdleen-openvpn.service"

# -------------------- Global command installer paths --------------------
LIB_DIR="/usr/local/lib/bahdleen-vpn"
MAIN_PATH="${LIB_DIR}/bahdleen-vpn.sh"
LAUNCHER="/usr/local/bin/bahdleen-vpn"
SUDOERS_FILE="/etc/sudoers.d/bahdleen-vpn"

# -------------------- Defaults --------------------
DEFAULT_OVPN_PORT="1194"
DEFAULT_OVPN_PROTO="udp"
DEFAULT_OVPN_NET="10.8.0.0"
DEFAULT_OVPN_MASK="255.255.255.0"

DEFAULT_WG_PORT="51820"
DEFAULT_WG_SERVER_ADDR="10.9.0.1/24"
DEFAULT_WG_POOL_BASE="10.9.0"

# -------------------- State vars --------------------
PUBLIC_ENDPOINT=""
DNS1=""
DNS2=""
NAT_IFACE=""

# -------------------- Root check --------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root: sudo $0"
    exit 1
  fi
}

# -------------------- Distro detection --------------------
DISTRO_FAMILY=""
DISTRO_NAME=""

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_NAME="${NAME:-unknown}"
    local id="${ID:-}"
    local like="${ID_LIKE:-}"

    case "${id}" in
      ubuntu|debian|linuxmint) DISTRO_FAMILY="debian" ;;
      fedora) DISTRO_FAMILY="fedora" ;;
      arch|manjaro) DISTRO_FAMILY="arch" ;;
      opensuse*|sles) DISTRO_FAMILY="suse" ;;
      *)
        if echo "${like}" | grep -qi "debian"; then DISTRO_FAMILY="debian"; fi
        if echo "${like}" | grep -qi "rhel\|fedora"; then DISTRO_FAMILY="fedora"; fi
        if echo "${like}" | grep -qi "arch"; then DISTRO_FAMILY="arch"; fi
        if echo "${like}" | grep -qi "suse"; then DISTRO_FAMILY="suse"; fi
        ;;
    esac
  fi

  if [[ -z "${DISTRO_FAMILY}" ]]; then
    err "Unsupported distro."
    err "Supported: Ubuntu, Debian, Mint, Fedora, Arch, Manjaro, openSUSE."
    exit 1
  fi
}

# -------------------- Debian repo/CA preflight --------------------
debian_preflight_repos() {
  local files=""
  files="$(grep -RIl "packages.openvpn.net/openvpn3" \
    /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)"

  if [[ -n "${files}" ]]; then
    warn "Found legacy OpenVPN3 repo entries. Disabling to prevent APT failures..."
    while read -r f; do
      [[ -f "$f" ]] || continue
      sed -i '\|packages.openvpn.net/openvpn3| s|^[[:space:]]*deb |# deb |' "$f" || true
    done <<< "${files}"
  fi

  rm -f /etc/apt/sources.list.d/openvpn3.list \
        /etc/apt/sources.list.d/openvpn3*.list 2>/dev/null || true
}

debian_ensure_ca() {
  if ! dpkg -s ca-certificates >/dev/null 2>&1; then
    warn "ca-certificates missing. Installing..."
    apt-get update -y || true
    apt-get install -y ca-certificates
  fi
}

# -------------------- Package manager wrappers --------------------
pkg_update() {
  case "${DISTRO_FAMILY}" in
    debian)
      debian_preflight_repos
      debian_ensure_ca
      apt-get update -y
      ;;
    fedora) dnf -y makecache ;;
    arch) pacman -Sy --noconfirm ;;
    suse) zypper --gpg-auto-import-keys refresh ;;
  esac
}

pkg_install_min_http() {
  case "${DISTRO_FAMILY}" in
    debian)
      debian_preflight_repos
      debian_ensure_ca
      apt-get install -y curl ca-certificates dnsutils
      ;;
    fedora) dnf install -y curl ca-certificates bind-utils ;;
    arch) pacman -S --noconfirm curl ca-certificates bind ;;
    suse) zypper --non-interactive install curl ca-certificates bind-utils ;;
  esac
}

pkg_install_core() {
  case "${DISTRO_FAMILY}" in
    debian)
      debian_preflight_repos
      debian_ensure_ca
      apt-get install -y openvpn easy-rsa wireguard curl iptables ca-certificates dnsutils
      ;;
    fedora)
      dnf install -y openvpn easy-rsa wireguard-tools curl iptables-services ca-certificates bind-utils
      ;;
    arch)
      pacman -S --noconfirm openvpn easy-rsa wireguard-tools curl iptables ca-certificates bind
      ;;
    suse)
      zypper --non-interactive install openvpn easy-rsa wireguard-tools curl iptables ca-certificates bind-utils
      ;;
  esac
}

pkg_upgrade_vpn() {
  case "${DISTRO_FAMILY}" in
    debian)
      debian_preflight_repos
      debian_ensure_ca
      apt-get update -y
      apt-get install -y --only-upgrade openvpn easy-rsa wireguard curl iptables ca-certificates dnsutils
      ;;
    fedora)
      dnf upgrade -y openvpn easy-rsa wireguard-tools curl iptables-services ca-certificates bind-utils
      ;;
    arch)
      pacman -Syu --noconfirm openvpn easy-rsa wireguard-tools curl iptables ca-certificates bind
      ;;
    suse)
      zypper --non-interactive update openvpn easy-rsa wireguard-tools curl iptables ca-certificates bind-utils
      ;;
  esac
}

pkg_remove_all() {
  case "${DISTRO_FAMILY}" in
    debian)
      debian_preflight_repos
      apt-get purge -y openvpn easy-rsa wireguard curl iptables ca-certificates dnsutils || true
      apt-get autoremove -y || true
      ;;
    fedora)
      dnf remove -y openvpn easy-rsa wireguard-tools curl iptables-services ca-certificates bind-utils || true
      ;;
    arch)
      pacman -Rns --noconfirm openvpn easy-rsa wireguard-tools curl iptables ca-certificates bind || true
      ;;
    suse)
      zypper --non-interactive remove openvpn easy-rsa wireguard-tools curl iptables ca-certificates bind-utils || true
      ;;
  esac
}

# -------------------- Directory prep --------------------
ensure_user_state_dirs() {
  mkdir -p "${STATE_DIR}" "${OVPN_CLIENT_OUT}" "${WG_CLIENT_OUT}"
  chown -R "${REAL_USER}:${REAL_USER}" \
    "${STATE_DIR}" "${OVPN_CLIENT_OUT}" "${WG_CLIENT_OUT}" 2>/dev/null || true
  chmod 700 "${STATE_DIR}" "${OVPN_CLIENT_OUT}" "${WG_CLIENT_OUT}"
}

ensure_system_dirs() {
  mkdir -p "${OVPN_SERVER_DIR}" "${EASYRSA_DIR}" "${WG_DIR}"
}

repair_directories() {
  banner
  info "Repairing directories..."
  ensure_user_state_dirs
  ensure_system_dirs
  ok "Directories ready."
  echo
  echo "OpenVPN exports:   ${OVPN_CLIENT_OUT}"
  echo "WireGuard exports: ${WG_CLIENT_OUT}"
  pause
}

# -------------------- State load/save --------------------
load_state() {
  ensure_user_state_dirs
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

save_state() {
  ensure_user_state_dirs
  cat > "${STATE_FILE}" <<EOF
PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT}"
DNS1="${DNS1}"
DNS2="${DNS2}"
NAT_IFACE="${NAT_IFACE}"
EOF
  chmod 600 "${STATE_FILE}"
  chown "${REAL_USER}:${REAL_USER}" "${STATE_FILE}" 2>/dev/null || true
}

# -------------------- Net helpers --------------------
detect_primary_iface() {
  ip route get 1.1.1.1 2>/dev/null |
    awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1
}

ensure_http_client() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  info "Installing minimal tools for public IP detection..."
  pkg_update || true
  pkg_install_min_http || true
}

detect_public_ip() {
  local ip=""

  # Must have default route for autodetection
  if ! ip route show default >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  # HTTPS-based checks
  if command -v curl >/dev/null 2>&1; then
    for url in \
      "https://api.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://checkip.amazonaws.com" \
      "https://icanhazip.com" \
      "https://ident.me"; do
      ip="$(curl -4 -s --max-time 5 "$url" 2>/dev/null || true)"
      ip="$(echo "${ip}" | tr -d ' \n\r\t')"
      if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "${ip}"
        return 0
      fi
    done
  fi

  # DNS-based fallback (works even if HTTPS blocked)
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -n1 || true)"
  elif command -v host >/dev/null 2>&1; then
    ip="$(host myip.opendns.com resolver1.opendns.com 2>/dev/null | awk "/has address/ {print \$4; exit}" || true)"
  elif command -v nslookup >/dev/null 2>&1; then
    ip="$(nslookup myip.opendns.com resolver1.opendns.com 2>/dev/null | awk "/Address: /{print \$2}" | tail -n1 || true)"
  fi

  ip="$(echo "${ip}" | tr -d ' \n\r\t')"
  if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "${ip}"
    return 0
  fi

  echo ""
}

# -------------------- Prompts --------------------
ask_ip_strategy() {
  echo
  info "Static IP check (private/LAN IP)"
  echo "OpenVPN/WireGuard work best when your PRIVATE IP is static."
  echo
  echo "1) Keep current network config"
  echo "2) I will set static IP manually"
  echo

  local choice=""
  safe_read "Choose [1-2]: " choice || return 1
  case "${choice:-1}" in
    1) ok "Keeping current network settings." ;;
    2) warn "Set a static private IP at OS/cloud level." ;;
    *) ok "Defaulting to keep current network settings." ;;
  esac
}

ask_public_endpoint() {
  echo
  info "Public endpoint for clients"

  ensure_http_client
  local detected=""
  detected="$(detect_public_ip)"

  if [[ -n "${PUBLIC_ENDPOINT}" ]]; then
    echo "Saved endpoint: ${PUBLIC_ENDPOINT}"
  fi

  if [[ -n "${detected}" ]]; then
    echo "Detected public IP: ${detected}"
    echo
    echo "1) Use detected IP (${detected})"
    echo "2) Use saved endpoint (${PUBLIC_ENDPOINT:-none})"
    echo "3) Enter custom PUBLIC IP or DOMAIN"
    echo

    local choice=""
    safe_read "Choose [1-3]: " choice || return 1

    case "${choice}" in
      1) PUBLIC_ENDPOINT="${detected}"; ok "Using detected IP."; return 0 ;;
      2)
        if [[ -n "${PUBLIC_ENDPOINT}" ]]; then ok "Using saved endpoint."; return 0; fi
        warn "No saved endpoint."
        ;;
      3) ;;
      *) PUBLIC_ENDPOINT="${detected}"; ok "Using detected IP."; return 0 ;;
    esac
  else
    warn "Could not auto-detect public IP."
    echo "This is common when:"
    echo "  - Your provider/ISP blocks public IP detection endpoints,"
    echo "  - The server has no outbound internet yet,"
    echo "  - DNS is not working,"
    echo "  - Or you're in a restricted lab environment."
    echo
    echo "Please enter your PUBLIC IP or DOMAIN manually."
  fi

  local ep=""
  while true; do
    safe_read "Enter PUBLIC IP or DOMAIN: " ep || return 1
    ep="$(echo "${ep}" | tr -d ' \t\r\n')"
    if [[ -n "${ep}" ]]; then
      PUBLIC_ENDPOINT="${ep}"
      ok "Using manual endpoint: ${PUBLIC_ENDPOINT}"
      return 0
    fi
    warn "Endpoint cannot be empty."
  done
}

ask_dns_choice() {
  echo
  info "DNS to push to VPN clients"
  echo "1) Cloudflare (1.1.1.1, 1.0.0.1)"
  echo "2) Google (8.8.8.8, 8.8.4.4)"
  echo "3) OpenDNS (208.67.222.222, 208.67.220.220)"
  echo "4) Custom"

  local choice=""
  while true; do
    safe_read "Choose [1-4]: " choice || return 1
    case "${choice}" in
      1) DNS1="1.1.1.1"; DNS2="1.0.0.1"; break ;;
      2) DNS1="8.8.8.8"; DNS2="8.8.4.4"; break ;;
      3) DNS1="208.67.222.222"; DNS2="208.67.220.220"; break ;;
      4)
        local d1="" d2=""
        safe_read "Enter primary DNS: " d1 || return 1
        safe_read "Enter secondary DNS (optional): " d2 || true
        d1="$(echo "${d1}" | tr -d ' \t\r\n')"
        d2="$(echo "${d2}" | tr -d ' \t\r\n')"
        [[ -z "${d1}" ]] && warn "Primary DNS cannot be empty." && continue
        DNS1="${d1}"; DNS2="${d2:-}"
        break ;;
      *) warn "Invalid selection. Use 1-4." ;;
    esac
  done
  ok "DNS set to: ${DNS1}${DNS2:+, ${DNS2}}"
}

ask_nat_iface() {
  local detected
  detected="$(detect_primary_iface)"
  detected="${detected:-eth0}"

  echo
  info "NAT interface detection"
  echo "Detected interface: ${detected}"

  local ans=""
  safe_read "Use this interface for NAT? [Y/n]: " ans || return 1
  ans="${ans,,}"

  if [[ "${ans}" == "n" || "${ans}" == "no" ]]; then
    local iface=""
    safe_read "Enter interface name: " iface || return 1
    NAT_IFACE="${iface}"
  else
    NAT_IFACE="${detected}"
  fi

  [[ -z "${NAT_IFACE}" ]] && NAT_IFACE="${detected}"
  ok "NAT interface: ${NAT_IFACE}"
}

collect_common_inputs() {
  ask_ip_strategy || return 1
  ask_public_endpoint || return 1
  ask_dns_choice || return 1
  ask_nat_iface || return 1
  save_state
}

# -------------------- Forwarding --------------------
enable_ip_forwarding() {
  info "Enabling IPv4 forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  cat > "${SYSCTL_FILE}" <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null || true
  ok "IPv4 forwarding enabled."
}

# -------------------- NAT persistence --------------------
write_nat_unit() {
  cat > "${NAT_UNIT}" <<EOF
[Unit]
Description=Bahdleen VPN NAT restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore ${NAT_RULES_FILE}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

apply_nat_rules() {
  info "Applying NAT rules for OpenVPN + WireGuard..."

  iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o "${NAT_IFACE}" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o "${NAT_IFACE}" -j MASQUERADE 2>/dev/null || true

  iptables -D FORWARD -i tun0 -o "${NAT_IFACE}" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "${NAT_IFACE}" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

  iptables -D FORWARD -i wg0 -o "${NAT_IFACE}" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "${NAT_IFACE}" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

  iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "${NAT_IFACE}" -j MASQUERADE
  iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "${NAT_IFACE}" -j MASQUERADE

  iptables -A FORWARD -i tun0 -o "${NAT_IFACE}" -j ACCEPT
  iptables -A FORWARD -i "${NAT_IFACE}" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

  iptables -A FORWARD -i wg0 -o "${NAT_IFACE}" -j ACCEPT
  iptables -A FORWARD -i "${NAT_IFACE}" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

  /usr/sbin/iptables-save > "${NAT_RULES_FILE}"
  chmod 600 "${NAT_RULES_FILE}"

  write_nat_unit
  systemctl daemon-reload
  systemctl enable --now bahdleen-vpn-nat.service

  ok "NAT configured and persistent."
}

# =========================================================
# OpenVPN
# =========================================================
openvpn_version() {
  openvpn --version 2>/dev/null | head -n1 | awk '{print $2}' || echo ""
}

ovpn_cipher_block() {
  local ver
  ver="$(openvpn_version)"
  if [[ "${ver}" == 2.4.* ]]; then
    cat <<'EOF'
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
EOF
  else
    cat <<'EOF'
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth SHA256
EOF
  fi
}

ovpn_init_easyrsa() {
  rm -rf "${EASYRSA_DIR}"
  mkdir -p "${EASYRSA_DIR}"

  if [[ -d "/usr/share/easy-rsa" ]]; then
    cp -r /usr/share/easy-rsa/* "${EASYRSA_DIR}/"
  elif [[ -d "/usr/share/easy-rsa/3" ]]; then
    cp -r /usr/share/easy-rsa/3/* "${EASYRSA_DIR}/"
  fi

  chmod +x "${EASYRSA_DIR}/easyrsa" 2>/dev/null || true
}

ovpn_build_pki() {
  info "Initializing Easy-RSA PKI..."
  ovpn_init_easyrsa

  pushd "${EASYRSA_DIR}" >/dev/null

  cat > vars <<'EOF'
set_var EASYRSA_REQ_COUNTRY    "GB"
set_var EASYRSA_REQ_PROVINCE   "England"
set_var EASYRSA_REQ_CITY       "London"
set_var EASYRSA_REQ_ORG        "BahdleenVPN"
set_var EASYRSA_REQ_EMAIL      "admin@example.com"
set_var EASYRSA_REQ_OU         "IT"
set_var EASYRSA_ALGO           "ec"
set_var EASYRSA_DIGEST         "sha256"
set_var EASYRSA_CERT_EXPIRE    "1080"
EOF

  ./easyrsa init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch build-server-full server nopass
  ./easyrsa gen-dh
  ./easyrsa gen-crl

  popd >/dev/null
  ok "PKI initialized."
}

ovpn_install_server_crypto() {
  info "Installing OpenVPN server keys/certs..."
  mkdir -p "${OVPN_SERVER_DIR}"

  install -m 600 "${PKI_DIR}/private/server.key" "${OVPN_SERVER_DIR}/server.key"
  install -m 644 "${PKI_DIR}/issued/server.crt" "${OVPN_SERVER_DIR}/server.crt"
  install -m 644 "${PKI_DIR}/ca.crt" "${OVPN_SERVER_DIR}/ca.crt"
  install -m 644 "${PKI_DIR}/dh.pem" "${OVPN_SERVER_DIR}/dh.pem"
  install -m 644 "${PKI_DIR}/crl.pem" "${OVPN_SERVER_DIR}/crl.pem"

  ok "Server crypto installed."
}

ovpn_generate_tls_key() {
  info "Generating tls-crypt key..."
  openvpn --genkey --secret "${OVPN_TLS_KEY}"
  chmod 600 "${OVPN_TLS_KEY}"
  ok "TLS key generated."
}

ovpn_write_server_conf() {
  local port proto port_in proto_in
  port="${DEFAULT_OVPN_PORT}"
  proto="${DEFAULT_OVPN_PROTO}"

  echo
  safe_read "OpenVPN port [${DEFAULT_OVPN_PORT}]: " port_in || return 1
  safe_read "Protocol udp/tcp [${DEFAULT_OVPN_PROTO}]: " proto_in || return 1
  port="${port_in:-$port}"
  proto="${proto_in:-$proto}"

  info "Writing OpenVPN server config..."

  cat > "${OVPN_SERVER_CONF}" <<EOF
port ${port}
proto ${proto}
dev tun

persist-key
persist-tun

topology subnet
server ${DEFAULT_OVPN_NET} ${DEFAULT_OVPN_MASK}

ca ${OVPN_SERVER_DIR}/ca.crt
cert ${OVPN_SERVER_DIR}/server.crt
key ${OVPN_SERVER_DIR}/server.key
dh ${OVPN_SERVER_DIR}/dh.pem

tls-crypt ${OVPN_TLS_KEY}
crl-verify ${OVPN_SERVER_DIR}/crl.pem

push "dhcp-option DNS ${DNS1}"
EOF

  if [[ -n "${DNS2:-}" ]]; then
    echo "push \"dhcp-option DNS ${DNS2}\"" >> "${OVPN_SERVER_CONF}"
  fi

  cat >> "${OVPN_SERVER_CONF}" <<'EOF'

push "redirect-gateway def1 bypass-dhcp"
keepalive 10 120
explicit-exit-notify 1
verb 3
EOF

  ovpn_cipher_block >> "${OVPN_SERVER_CONF}"

  chmod 600 "${OVPN_SERVER_CONF}"
  ok "Server config created."
}

ovpn_write_unit() {
  cat > "${OVPN_UNIT}" <<EOF
[Unit]
Description=Bahdleen OpenVPN Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config ${OVPN_SERVER_CONF}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

ovpn_start() {
  ovpn_write_unit
  systemctl daemon-reload
  systemctl enable --now bahdleen-openvpn.service
  ok "OpenVPN service started (bahdleen-openvpn)."
}

setup_openvpn() {
  info "Setting up OpenVPN..."
  ovpn_build_pki
  ovpn_generate_tls_key
  ovpn_install_server_crypto
  ovpn_write_server_conf
  ovpn_start
  ok "OpenVPN setup complete."
}

ovpn_add_client() {
  banner
  info "Add OpenVPN client"

  ensure_user_state_dirs
  load_state

  if [[ ! -x "${EASYRSA_DIR}/easyrsa" || ! -d "${PKI_DIR}" ]]; then
    err "OpenVPN PKI not found. Run OpenVPN setup first."
    pause
    return 1
  fi

  local client=""
  safe_read "Enter client username: " client || return 1
  client="${client// /}"
  [[ -z "${client}" ]] && err "Client name cannot be empty." && pause && return 1

  local days=""
  safe_read "Certificate validity in days [1080]: " days || return 1
  days="${days:-1080}"
  if ! [[ "${days}" =~ ^[0-9]+$ ]]; then
    warn "Invalid number. Using 1080."
    days="1080"
  fi

  local pass_choice=""
  safe_read "Protect client key with password? [y/N]: " pass_choice || return 1
  pass_choice="${pass_choice,,}"

  pushd "${EASYRSA_DIR}" >/dev/null
  if [[ "${pass_choice}" == "y" || "${pass_choice}" == "yes" ]]; then
    info "Easy-RSA will prompt you to set a passphrase."
    EASYRSA_CERT_EXPIRE="${days}" ./easyrsa build-client-full "${client}"
  else
    EASYRSA_CERT_EXPIRE="${days}" ./easyrsa --batch build-client-full "${client}" nopass
  fi
  ./easyrsa gen-crl
  popd >/dev/null

  install -m 644 "${PKI_DIR}/crl.pem" "${OVPN_SERVER_DIR}/crl.pem" 2>/dev/null || true
  systemctl restart bahdleen-openvpn.service 2>/dev/null || true

  local port proto
  port="$(awk '/^port /{print $2; exit}' "${OVPN_SERVER_CONF}" 2>/dev/null || echo "${DEFAULT_OVPN_PORT}")"
  proto="$(awk '/^proto /{print $2; exit}' "${OVPN_SERVER_CONF}" 2>/dev/null || echo "${DEFAULT_OVPN_PROTO}")"

  local ca crt key ta
  ca="${PKI_DIR}/ca.crt"
  crt="${PKI_DIR}/issued/${client}.crt"
  key="${PKI_DIR}/private/${client}.key"
  ta="${OVPN_TLS_KEY}"

  mkdir -p "${OVPN_CLIENT_OUT}/${client}"
  chmod 700 "${OVPN_CLIENT_OUT}/${client}"
  chown -R "${REAL_USER}:${REAL_USER}" "${OVPN_CLIENT_OUT}" 2>/dev/null || true

  cat > "${OVPN_CLIENT_OUT}/${client}/${client}.ovpn" <<EOF
client
dev tun
proto ${proto}
remote ${PUBLIC_ENDPOINT} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server
verb 3

<ca>
$(cat "${ca}")
</ca>
<cert>
$(awk '/BEGIN CERTIFICATE/{f=1} f{print} /END CERTIFICATE/{f=0}' "${crt}")
</cert>
<key>
$(cat "${key}")
</key>
<tls-crypt>
$(cat "${ta}")
</tls-crypt>
EOF

  chmod 600 "${OVPN_CLIENT_OUT}/${client}/${client}.ovpn"
  chown "${REAL_USER}:${REAL_USER}" "${OVPN_CLIENT_OUT}/${client}/${client}.ovpn" 2>/dev/null || true

  ok "OpenVPN client exported:"
  echo "  ${OVPN_CLIENT_OUT}/${client}/${client}.ovpn"
  pause
}

ovpn_revoke_client() {
  banner
  info "Revoke OpenVPN client"

  if [[ ! -x "${EASYRSA_DIR}/easyrsa" ]]; then
    err "Easy-RSA not initialized."
    pause
    return 1
  fi

  local client=""
  safe_read "Enter client username to revoke: " client || return 1
  client="${client// /}"
  [[ -z "${client}" ]] && err "Client name cannot be empty." && pause && return 1

  pushd "${EASYRSA_DIR}" >/dev/null
  ./easyrsa --batch revoke "${client}"
  ./easyrsa gen-crl
  popd >/dev/null

  install -m 644 "${PKI_DIR}/crl.pem" "${OVPN_SERVER_DIR}/crl.pem" 2>/dev/null || true
  rm -rf "${OVPN_CLIENT_OUT:?}/${client}" 2>/dev/null || true

  systemctl restart bahdleen-openvpn.service 2>/dev/null || true
  ok "Client revoked: ${client}"
  pause
}

# =========================================================
# WireGuard
# =========================================================
wg_generate_server_keys() {
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"
  umask 077

  if [[ ! -f "${WG_SERVER_PRIV}" ]]; then
    info "Generating WireGuard server keys..."
    wg genkey | tee "${WG_SERVER_PRIV}" | wg pubkey > "${WG_SERVER_PUB}"
  fi

  chmod 600 "${WG_SERVER_PRIV}" "${WG_SERVER_PUB}"
  ok "WireGuard server keys ready."
}

wg_write_server_conf() {
  local port port_in
  port="${DEFAULT_WG_PORT}"

  echo
  safe_read "WireGuard port [${DEFAULT_WG_PORT}]: " port_in || return 1
  port="${port_in:-$port}"

  local priv
  priv="$(cat "${WG_SERVER_PRIV}")"

  info "Writing WireGuard server config..."

  cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${DEFAULT_WG_SERVER_ADDR}
ListenPort = ${port}
PrivateKey = ${priv}
SaveConfig = false
EOF

  chmod 600 "${WG_CONF}"
  : > "${WG_PEERS_DB}"
  chmod 600 "${WG_PEERS_DB}"

  ok "WireGuard server config created."
}

wg_start() {
  systemctl enable --now wg-quick@wg0 2>/dev/null || true
  ok "WireGuard service started (wg-quick@wg0)."
}

setup_wireguard() {
  info "Setting up WireGuard..."
  rm -f "${WG_CONF}" "${WG_PEERS_DB}" 2>/dev/null || true
  wg_generate_server_keys
  wg_write_server_conf
  wg_start
  ok "WireGuard setup complete."
}

wg_next_peer_ip() {
  local used
  used="$(awk -F'|' '{print $3}' "${WG_PEERS_DB}" 2>/dev/null | awk -F'[./]' '{print $4}' | sort -n | uniq || true)"
  local i
  for i in $(seq 2 254); do
    if ! echo "${used}" | grep -qx "${i}"; then
      echo "${DEFAULT_WG_POOL_BASE}.${i}/32"
      return 0
    fi
  done
  err "No free IPs left in ${DEFAULT_WG_POOL_BASE}.0/24"
  return 1
}

wg_add_peer() {
  banner
  info "Add WireGuard peer"

  ensure_user_state_dirs
  load_state

  [[ ! -f "${WG_CONF}" ]] && err "WireGuard not configured. Run setup first." && pause && return 1

  local peer=""
  safe_read "Enter peer name: " peer || return 1
  peer="${peer// /}"
  [[ -z "${peer}" ]] && err "Peer name cannot be empty." && pause && return 1

  mkdir -p "${WG_CLIENT_OUT}/${peer}"
  chmod 700 "${WG_CLIENT_OUT}/${peer}"
  chown -R "${REAL_USER}:${REAL_USER}" "${WG_CLIENT_OUT}" 2>/dev/null || true

  umask 077
  local priv_key pub_key
  priv_key="$(wg genkey)"
  pub_key="$(printf "%s" "${priv_key}" | wg pubkey)"

  local peer_ip
  peer_ip="$(wg_next_peer_ip)" || return 1
  local peer_ip_addr="${peer_ip%/32}"

  cat >> "${WG_CONF}" <<EOF

[Peer]
# ${peer}
PublicKey = ${pub_key}
AllowedIPs = ${peer_ip}
EOF

  echo "${peer}|${pub_key}|${peer_ip}" >> "${WG_PEERS_DB}"

  systemctl restart wg-quick@wg0 2>/dev/null || true

  local server_pub port
  server_pub="$(cat "${WG_SERVER_PUB}")"
  port="$(grep -E '^ListenPort' "${WG_CONF}" | awk -F= '{gsub(/ /,"",$2); print $2}' | head -n1)"
  port="${port:-$DEFAULT_WG_PORT}"

  cat > "${WG_CLIENT_OUT}/${peer}/${peer}.conf" <<EOF
[Interface]
PrivateKey = ${priv_key}
Address = ${peer_ip_addr}/32
DNS = ${DNS1}${DNS2:+, ${DNS2}}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${PUBLIC_ENDPOINT}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  chmod 600 "${WG_CLIENT_OUT}/${peer}/${peer}.conf"
  chown "${REAL_USER}:${REAL_USER}" "${WG_CLIENT_OUT}/${peer}/${peer}.conf" 2>/dev/null || true

  ok "WireGuard peer exported:"
  echo "  ${WG_CLIENT_OUT}/${peer}/${peer}.conf"
  pause
}

wg_remove_peer() {
  banner
  info "Remove WireGuard peer"

  local peer=""
  safe_read "Enter peer name to remove: " peer || return 1
  peer="${peer// /}"
  [[ -z "${peer}" ]] && err "Peer name cannot be empty." && pause && return 1

  [[ ! -f "${WG_PEERS_DB}" ]] && warn "Peers DB missing." && pause && return 0

  local record pub ip
  record="$(grep -F "^${peer}|" "${WG_PEERS_DB}" 2>/dev/null || true)"
  [[ -z "${record}" ]] && warn "Peer not found." && pause && return 0

  pub="$(echo "${record}" | awk -F'|' '{print $2}')"
  ip="$(echo "${record}" | awk -F'|' '{print $3}')"

  local tmp
  tmp="$(mktemp)"

  awk -v PUB="${pub}" -v IP="${ip}" '
    BEGIN {block=0; mark=0; buf=""}
    /^\[Peer\]$/ {block=1; mark=0; buf=$0 ORS; next}
    block==1 {
      buf = buf $0 ORS
      if ($0 ~ "PublicKey *= *"PUB) mark=1
      if ($0 ~ "AllowedIPs *= *"IP) mark=1
      if ($0 == "") {
        if (mark==0) printf "%s", buf
        block=0; buf=""; mark=0
      }
      next
    }
    {print}
    END { if (block==1 && mark==0) printf "%s", buf }
  ' "${WG_CONF}" > "${tmp}"

  mv "${tmp}" "${WG_CONF}"
  chmod 600 "${WG_CONF}"

  grep -v -F "^${peer}|" "${WG_PEERS_DB}" > "${WG_PEERS_DB}.tmp" || true
  mv "${WG_PEERS_DB}.tmp" "${WG_PEERS_DB}"
  chmod 600 "${WG_PEERS_DB}"

  rm -rf "${WG_CLIENT_OUT:?}/${peer}" 2>/dev/null || true
  systemctl restart wg-quick@wg0 2>/dev/null || true

  ok "Peer removed: ${peer}"
  pause
}

# =========================================================
# Setup flows
# =========================================================
setup_common_base() {
  ensure_user_state_dirs
  ensure_system_dirs
  pkg_update
  pkg_install_core
  enable_ip_forwarding
}

setup_openvpn_flow() {
  banner
  info "Fresh setup: OpenVPN"
  load_state
  collect_common_inputs || { err "Cancelled."; pause; return 1; }
  setup_common_base
  setup_openvpn
  apply_nat_rules
  ok "OpenVPN setup finished."
  pause
}

setup_wireguard_flow() {
  banner
  info "Fresh setup: WireGuard"
  load_state
  collect_common_inputs || { err "Cancelled."; pause; return 1; }
  setup_common_base
  setup_wireguard
  apply_nat_rules
  ok "WireGuard setup finished."
  pause
}

setup_both_flow() {
  banner
  info "Fresh setup: OpenVPN + WireGuard"
  load_state
  collect_common_inputs || { err "Cancelled."; pause; return 1; }
  setup_common_base
  setup_openvpn
  setup_wireguard
  apply_nat_rules
  ok "Both VPNs installed and configured."
  pause
}

# =========================================================
# Status / Update
# =========================================================
show_status() {
  banner
  echo "Detected OS: ${DISTRO_NAME} (${DISTRO_FAMILY})"
  echo "User: ${REAL_USER}"
  echo
  echo "Client export locations:"
  echo "  OpenVPN:   ${OVPN_CLIENT_OUT}"
  echo "  WireGuard: ${WG_CLIENT_OUT}"
  echo
  systemctl status bahdleen-openvpn.service --no-pager 2>/dev/null || echo "OpenVPN: Not running / not installed."
  echo
  systemctl status wg-quick@wg0 --no-pager 2>/dev/null || echo "WireGuard: Not running / not installed."
  echo
  systemctl status bahdleen-vpn-nat.service --no-pager 2>/dev/null || echo "NAT: Not enabled."
  echo
  pause
}

update_libraries() {
  banner
  info "Updating VPN libraries/packages..."
  pkg_upgrade_vpn
  ok "Update completed."
  pause
}

# =========================================================
# Cleanup leftovers
# =========================================================
cleanup_leftovers() {
  banner
  warn "This clears leftover configs/services and fixes broken Debian OpenVPN3 repo entries."
  echo
  local c=""
  safe_read "Type CLEAN to proceed: " c || return 1
  [[ "${c}" != "CLEAN" ]] && info "Cancelled." && pause && return 0

  systemctl disable --now bahdleen-openvpn.service 2>/dev/null || true
  systemctl disable --now wg-quick@wg0 2>/dev/null || true
  systemctl disable --now bahdleen-vpn-nat.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  rm -f "${OVPN_UNIT}" "${NAT_UNIT}" "${SYSCTL_FILE}" "${NAT_RULES_FILE}" 2>/dev/null || true
  rm -rf "${OVPN_DIR}" "${WG_DIR}" 2>/dev/null || true

  if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
    debian_preflight_repos
    debian_ensure_ca
    apt-get update -y || true
  fi

  ok "System leftovers cleared."
  echo
  echo "Optional user cleanup:"
  echo "  rm -rf ${STATE_DIR} ${OVPN_CLIENT_OUT} ${WG_CLIENT_OUT}"
  echo
  pause
}

reset_reinstall_both() {
  banner
  warn "This will WIPE and REINSTALL BOTH stacks fresh."
  echo
  local c=""
  safe_read "Type RESET to proceed: " c || return 1
  [[ "${c}" != "RESET" ]] && info "Cancelled." && pause && return 0

  cleanup_leftovers
  setup_both_flow
}

uninstall_all() {
  banner
  warn "This removes OpenVPN + WireGuard + Bahdleen + user exports."
  echo
  local c=""
  safe_read "Type UNINSTALL to confirm: " c || return 1
  [[ "${c}" != "UNINSTALL" ]] && info "Cancelled." && pause && return 0

  cleanup_leftovers

  rm -f "${LAUNCHER}" 2>/dev/null || true
  rm -rf "${LIB_DIR}" 2>/dev/null || true
  rm -f "${SUDOERS_FILE}" 2>/dev/null || true

  rm -rf "${STATE_DIR}" "${OVPN_CLIENT_OUT}" "${WG_CLIENT_OUT}" 2>/dev/null || true

  pkg_remove_all

  ok "Uninstalled."
  pause
}

# =========================================================
# ✅ GUARANTEED Global command installer (updated)
# =========================================================
install_global_command() {
  banner
  info "Install global command: bahdleen-vpn"
  echo
  echo "This will install:"
  echo "  Script   -> ${MAIN_PATH}"
  echo "  Command  -> ${LAUNCHER}"
  echo
  echo "And set passwordless sudo for ONLY this command for:"
  echo "  User -> ${REAL_USER}"
  echo
  warn "Security note:"
  echo "This does NOT grant broad sudo. It restricts to this exact script path."
  echo

  local c=""
  safe_read "Proceed? [Y/n]: " c || return 1
  c="${c,,}"
  if [[ "${c}" == "n" || "${c}" == "no" ]]; then
    info "Cancelled."
    pause
    return 0
  fi

  mkdir -p "${LIB_DIR}"

  # Resolve currently running script path
  local self
  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  # Copy script into system lib
  cp -f "${self}" "${MAIN_PATH}"
  chmod 755 "${MAIN_PATH}"

  # Create launcher (no sudo typing required)
  cat > "${LAUNCHER}" <<EOF
#!/usr/bin/env bash
exec sudo -n ${MAIN_PATH}
EOF
  chmod 755 "${LAUNCHER}"

  # Tight sudoers rule for the real user only
  cat > "${SUDOERS_FILE}" <<EOF
${REAL_USER} ALL=(root) NOPASSWD: ${MAIN_PATH}
EOF
  chmod 440 "${SUDOERS_FILE}"

  # Validate install
  if [[ ! -f "${MAIN_PATH}" ]]; then
    err "Install failed: missing ${MAIN_PATH}"
    pause
    return 1
  fi
  if [[ ! -f "${LAUNCHER}" ]]; then
    err "Install failed: missing ${LAUNCHER}"
    pause
    return 1
  fi
  if [[ ! -f "${SUDOERS_FILE}" ]]; then
    err "Install failed: missing ${SUDOERS_FILE}"
    pause
    return 1
  fi

  ok "Global command installed successfully."
  echo
  echo "Try now:"
  echo "  bahdleen-vpn"
  echo
  pause
}

# =========================================================
# Help
# =========================================================
show_help() {
  banner
  cat <<EOF
Bahdleen VPN Manager

OS auto-detected via /etc/os-release.

Public IP detection:
- Uses multiple HTTPS endpoints.
- Falls back to DNS queries.
- If provider/ISP blocks detection, you'll be asked to enter manually.

Client exports:
- OpenVPN:   ${OVPN_CLIENT_OUT}
- WireGuard: ${WG_CLIENT_OUT}

Services:
- OpenVPN:   bahdleen-openvpn.service
- WireGuard: wg-quick@wg0
- NAT:       bahdleen-vpn-nat.service

Global command:
- Use menu option to install "bahdleen-vpn"
EOF
  pause
}

# =========================================================
# Menu
# =========================================================
menu() {
  banner
  echo "Detected OS: ${DISTRO_NAME} (${DISTRO_FAMILY})"
  echo "User: ${REAL_USER}"
  echo
  echo "Exports:"
  echo "  OpenVPN:   ${OVPN_CLIENT_OUT}"
  echo "  WireGuard: ${WG_CLIENT_OUT}"
  echo
  echo "1) Setup OpenVPN"
  echo "2) Setup WireGuard"
  echo "3) Setup BOTH"
  echo "4) Add OpenVPN client (password + expiry)"
  echo "5) Revoke OpenVPN client"
  echo "6) Add WireGuard peer"
  echo "7) Remove WireGuard peer"
  echo "8) Status"
  echo "9) Update libraries/packages"
  echo "10) Repair directories"
  echo "11) Cleanup leftovers"
  echo "12) Reset & Reinstall BOTH"
  echo "13) Uninstall EVERYTHING"
  echo "14) Install global command (bahdleen-vpn)"
  echo "15) Help"
  echo "0) Exit"
  echo
}

main_loop() {
  require_root
  detect_distro
  ensure_user_state_dirs
  ensure_system_dirs
  load_state

  while true; do
    menu
    local opt=""
    safe_read "Select option: " opt || exit 1

    case "${opt}" in
      1) setup_openvpn_flow ;;
      2) setup_wireguard_flow ;;
      3) setup_both_flow ;;
      4) ovpn_add_client ;;
      5) ovpn_revoke_client ;;
      6) wg_add_peer ;;
      7) wg_remove_peer ;;
      8) show_status ;;
      9) update_libraries ;;
      10) repair_directories ;;
      11) cleanup_leftovers ;;
      12) reset_reinstall_both ;;
      13) uninstall_all ;;
      14) install_global_command ;;
      15) show_help ;;
      0) exit 0 ;;
      *) warn "Invalid option."; pause ;;
    esac
  done
}

main_loop
