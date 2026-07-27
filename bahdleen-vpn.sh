#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#  B A H D L E E N  -  V P N
#  OpenVPN + WireGuard installer/manager (multi-distro)
#
#  Exports clients to:
#     ~/ovpn-clients
#     ~/wireguard-clients
#
#  Key to start after install:
#     bahdleen-vpn
# ============================================================

SCRIPT_NAME="bahdleen-vpn"
SCRIPT_VERSION="1.1.0"
SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_SELF_DIR="$(dirname "${SCRIPT_SELF}")"

# ----------------------------
# Server paths
# ----------------------------
OVPN_DIR="/etc/openvpn"
OVPN_SERVER_DIR="${OVPN_DIR}/server"
OVPN_EASYRSA_DIR="${OVPN_DIR}/easy-rsa"
# shellcheck disable=SC2034
OVPN_SERVER_NAME="bahdleen-openvpn"
OVPN_SERVER_CONF="${OVPN_SERVER_DIR}/server.conf"

WG_DIR="/etc/wireguard"
WG_IF="wg0"
WG_CONF="${WG_DIR}/${WG_IF}.conf"

# ----------------------------
# User context
# ----------------------------
RUN_USER="${SUDO_USER:-${USER}}"

get_user_home() {
    local u="$1"
    getent passwd "$u" | cut -d: -f6
}

USER_HOME="$(get_user_home "${RUN_USER}")"
[[ -z "${USER_HOME}" ]] && USER_HOME="/home/${RUN_USER}"

# ----------------------------
# Export dirs in HOME
# ----------------------------
OVPN_EXPORT_BASE="${USER_HOME}/ovpn-clients"
WG_EXPORT_BASE="${USER_HOME}/wireguard-clients"

# ----------------------------
# State dir in HOME
# ----------------------------
STATE_DIR="${USER_HOME}/.bahdleen-vpn"
ENDPOINT_FILE="${STATE_DIR}/endpoint.txt"
DNS_FILE="${STATE_DIR}/dns.txt"

# ----------------------------
# Defaults
# ----------------------------
DEFAULT_OVPN_PORT="1194"
DEFAULT_WG_PORT="51820"

# ----------------------------
# Networks
# ----------------------------
OVPN_NET="10.8.0.0"
OVPN_MASK="255.255.255.0"
# shellcheck disable=SC2034
WG_NET="10.20.0.0/24"
WG_SERVER_IP="10.20.0.1/24"

# ============================================================
# UI Helpers
# ============================================================

if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'
    C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

clr() { printf '\033c'; }
info() { printf "${C_CYAN}[INFO]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[ OK ]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}[ERR ]${C_RESET} %s\n" "$*" >&2; }

pause() {
    printf "Press Enter to continue..."
    read -r _
}

# Friendly message instead of a raw bash stack trace on unexpected failures.
# (Deliberate `need_root || return 1` / `[[ ... ]] || return 1` guards don't
# reach this trap since their non-zero status is already consumed by && / ||.)
on_error() {
    local line="$1" code="$2"
    err "Unexpected error on line ${line} (exit code ${code})."
    err "Re-run with: bash -x ${SCRIPT_SELF} to see exactly what failed."
}
trap 'on_error "${LINENO}" "$?"' ERR

ascii_banner() {
cat <<'EOF'
██████╗  █████╗ ███████╗██╗  ██╗██╗     ███████╗███████╗███╗   ██╗
██╔══██╗██╔══██╗██╔════╝██║  ██║██║     ██╔════╝██╔════╝████╗  ██║
██████╔╝███████║█████╗  ███████║██║     █████╗  █████╗  ██╔██╗ ██║
██╔══██╗██╔══██║██╔══╝  ██╔══██║██║     ██╔══╝  ██╔══╝  ██║╚██╗██║
██████╔╝██║  ██║███████╗██║  ██║███████╗███████╗███████╗██║ ╚████║
╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═══╝
EOF
printf "\n            B A H D L E E N   -   V P N\n\n"
}

# ============================================================
# Privileges
# ============================================================

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "This action requires root. Use option 1 to install '${SCRIPT_NAME}' global command."
        return 1
    fi
    return 0
}

# ============================================================
# OS detection & package manager
# ============================================================

OS_FAMILY="unknown"
OS_PRETTY="unknown"
PKG_MGR=""

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_PRETTY="${PRETTY_NAME:-unknown}"
        local id="${ID:-}"
        local like="${ID_LIKE:-}"

        case "${id}" in
            ubuntu|debian|linuxmint|linuxlite)
                OS_FAMILY="debian" ;;
            fedora|rhel|centos)
                OS_FAMILY="fedora" ;;
            arch|manjaro)
                OS_FAMILY="arch" ;;
            opensuse*|sles)
                OS_FAMILY="suse" ;;
            *)
                [[ "${like}" == *"debian"* ]] && OS_FAMILY="debian"
                [[ "${like}" == *"rhel"* || "${like}" == *"fedora"* ]] && OS_FAMILY="fedora"
                [[ "${like}" == *"arch"* ]] && OS_FAMILY="arch"
                [[ "${like}" == *"suse"* ]] && OS_FAMILY="suse"
                ;;
        esac
    fi

    case "${OS_FAMILY}" in
        debian) PKG_MGR="apt" ;;
        fedora) PKG_MGR="dnf" ;;
        arch)   PKG_MGR="pacman" ;;
        suse)   PKG_MGR="zypper" ;;
        *)      PKG_MGR="" ;;
    esac
}

pkg_update() {
    need_root || return 1
    case "${PKG_MGR}" in
        apt) apt-get update -y ;;
        dnf) dnf -y makecache ;;
        pacman) pacman -Sy --noconfirm ;;
        zypper) zypper --non-interactive refresh ;;
        *) err "Unsupported OS/package manager."; return 1 ;;
    esac
}

pkg_install() {
    need_root || return 1
    local pkgs=("$@")
    case "${PKG_MGR}" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
        dnf) dnf install -y "${pkgs[@]}" ;;
        pacman) pacman -S --noconfirm "${pkgs[@]}" ;;
        zypper) zypper --non-interactive install "${pkgs[@]}" ;;
        *) err "Unsupported OS/package manager."; return 1 ;;
    esac
}

pkg_remove() {
    need_root || return 1
    local pkgs=("$@")
    case "${PKG_MGR}" in
        apt)
            apt-get remove -y "${pkgs[@]}" || true
            apt-get autoremove -y || true ;;
        dnf) dnf remove -y "${pkgs[@]}" || true ;;
        pacman) pacman -Rns --noconfirm "${pkgs[@]}" || true ;;
        zypper) zypper --non-interactive remove "${pkgs[@]}" || true ;;
        *) true ;;
    esac
}

# ============================================================
# Directories
# ============================================================

prepare_dirs() {
    mkdir -p "${OVPN_EXPORT_BASE}" "${WG_EXPORT_BASE}" "${STATE_DIR}"
    chown -R "${RUN_USER}:${RUN_USER}" \
        "${OVPN_EXPORT_BASE}" "${WG_EXPORT_BASE}" "${STATE_DIR}" 2>/dev/null || true
    ok "Directories ready."
}

repair_dirs() {
    info "Repairing export/state directories..."
    prepare_dirs
    ok "Directories repaired."
}

# ============================================================
# Static IP check (informational)
# ============================================================

static_ip_check() {
    info "Static IP check (private/LAN IP)"
    printf "OpenVPN/WireGuard work best when your PRIVATE IP is static.\n\n"
    printf "1) Keep current network config\n"
    printf "2) I will set static IP manually\n\n"

    local choice
    read -r -p "Choose [1-2]: " choice
    case "${choice}" in
        1) ok "Keeping current network settings." ;;
        2) warn "Proceeding without changes. Ensure your private/LAN IP remains stable." ;;
        *) ok "Keeping current network settings." ;;
    esac
}

# ============================================================
# Public endpoint detection
# ============================================================

install_ip_tools_if_needed() {
    need_root || return 1
    case "${PKG_MGR}" in
        apt) pkg_install ca-certificates curl dnsutils openssl ;;
        dnf) pkg_install ca-certificates curl bind-utils openssl ;;
        pacman) pkg_install ca-certificates curl bind openssl ;;
        zypper) pkg_install ca-certificates curl bind-utils openssl ;;
        *) true ;;
    esac
}

detect_public_ip() {
    local ip=""
    ip="$(curl -4 -s --max-time 4 https://api.ipify.org || true)"
    [[ -z "$ip" ]] && ip="$(curl -4 -s --max-time 4 https://ifconfig.me/ip || true)"
    [[ -z "$ip" ]] && ip="$(curl -4 -s --max-time 4 https://icanhazip.com || true)"
    ip="${ip//$'\n'/}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && printf '%s\n' "$ip"
}

choose_public_endpoint() {
    info "Public endpoint for clients"
    info "Installing minimal tools for public IP detection..."

    if [[ "${EUID}" -eq 0 ]]; then
        install_ip_tools_if_needed || true
    fi

    local saved="none"
    [[ -f "${ENDPOINT_FILE}" ]] && saved="$(cat "${ENDPOINT_FILE}")"

    local detected=""
    detected="$(detect_public_ip || true)"

    if [[ -n "${detected}" ]]; then
        ok "Detected public IP: ${detected}"
    else
        warn "Could not auto-detect public IP."
        warn "Your provider/firewall may block outbound IP detection."
        warn "Please enter your PUBLIC IP or DOMAIN manually."
    fi

    printf "\n"
    printf "1) Use detected IP (%s)\n" "${detected:-unavailable}"
    printf "2) Use saved endpoint (%s)\n" "${saved}"
    printf "3) Enter custom PUBLIC IP or DOMAIN\n\n"

    local choice endpoint
    read -r -p "Choose [1-3]: " choice

    case "${choice}" in
        1)
            if [[ -n "${detected}" ]]; then endpoint="${detected}"
            else read -r -p "Enter PUBLIC IP or DOMAIN: " endpoint; fi ;;
        2)
            if [[ "${saved}" != "none" && -n "${saved}" ]]; then endpoint="${saved}"
            else read -r -p "Enter PUBLIC IP or DOMAIN: " endpoint; fi ;;
        3|*)
            read -r -p "Enter PUBLIC IP or DOMAIN: " endpoint ;;
    esac

    [[ -z "${endpoint}" ]] && { err "Endpoint cannot be empty."; return 1; }

    printf '%s\n' "${endpoint}" > "${ENDPOINT_FILE}"
    chown "${RUN_USER}:${RUN_USER}" "${ENDPOINT_FILE}" 2>/dev/null || true
    ok "Endpoint set to: ${endpoint}"
}

get_saved_endpoint() {
    [[ -f "${ENDPOINT_FILE}" ]] && cat "${ENDPOINT_FILE}"
}

# ============================================================
# DNS selection
# ============================================================

choose_dns() {
    info "DNS to push to VPN clients"
    printf "1) Cloudflare (1.1.1.1, 1.0.0.1)\n"
    printf "2) Google (8.8.8.8, 8.8.4.4)\n"
    printf "3) OpenDNS (208.67.222.222, 208.67.220.220)\n"
    printf "4) Custom\n"

    local choice dns1 dns2
    read -r -p "Choose [1-4]: " choice

    case "${choice}" in
        1) dns1="1.1.1.1"; dns2="1.0.0.1" ;;
        2) dns1="8.8.8.8"; dns2="8.8.4.4" ;;
        3) dns1="208.67.222.222"; dns2="208.67.220.220" ;;
        4)
            read -r -p "Enter primary DNS: " dns1
            read -r -p "Enter secondary DNS (optional): " dns2 ;;
        *) dns1="1.1.1.1"; dns2="1.0.0.1" ;;
    esac

    [[ -z "${dns1}" ]] && { err "DNS cannot be empty."; return 1; }

    printf '%s,%s\n' "${dns1}" "${dns2:-}" > "${DNS_FILE}"
    chown "${RUN_USER}:${RUN_USER}" "${DNS_FILE}" 2>/dev/null || true
    ok "DNS set to: ${dns1}${dns2:+, ${dns2}}"
}

get_saved_dns() {
    if [[ -f "${DNS_FILE}" ]]; then
        cat "${DNS_FILE}"
    else
        printf "1.1.1.1,1.0.0.1\n"
    fi
}

# ============================================================
# NAT interface detection (stdout-clean)
# ============================================================

detect_primary_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

choose_nat_iface() {
    info "NAT interface detection" >&2

    local iface ans
    iface="$(detect_primary_iface || true)"
    [[ -z "${iface}" ]] && iface="eth0"

    printf "Detected interface: %s\n" "${iface}" >&2
    read -r -p "Use this interface for NAT? [Y/n]: " ans
    ans="${ans:-Y}"

    if [[ "${ans}" =~ ^[Nn]$ ]]; then
        read -r -p "Enter interface name: " iface
    fi

    [[ -z "${iface}" ]] && { err "Interface cannot be empty." >&2; return 1; }
    printf '%s\n' "${iface}"
}

enable_ip_forwarding() {
    need_root || return 1
    info "Enabling IPv4 forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        printf '\nnet.ipv4.ip_forward=1\n' >> /etc/sysctl.conf
    fi

    ok "IP forwarding enabled."
}

ensure_nat_tools() {
    need_root || return 1
    case "${PKG_MGR}" in
        apt) pkg_install iptables-persistent netfilter-persistent ;;
        dnf) pkg_install iptables iptables-services ;;
        pacman) pkg_install iptables ;;
        zypper) pkg_install iptables ;;
        *) true ;;
    esac
}

apply_nat_rules_both() {
    need_root || return 1
    local iface="$1"

    info "Applying NAT rules for OpenVPN + WireGuard..."

    iptables -t nat -C POSTROUTING -s "${OVPN_NET}/24" -o "${iface}" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "${OVPN_NET}/24" -o "${iface}" -j MASQUERADE

    iptables -t nat -C POSTROUTING -s "10.20.0.0/24" -o "${iface}" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "10.20.0.0/24" -o "${iface}" -j MASQUERADE

    # MASQUERADE alone only rewrites addresses; it does not grant permission to
    # forward the traffic. Distros/tools (notably Docker, which sets the
    # FORWARD chain's default policy to DROP) can leave VPN clients connected
    # but unable to reach the internet unless we explicitly allow forwarding
    # for the tunnel interfaces.
    iptables -C FORWARD -i tun+ -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD -i tun+ -j ACCEPT
    iptables -C FORWARD -o tun+ -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD -o tun+ -j ACCEPT
    iptables -C FORWARD -i "${WG_IF}" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD -i "${WG_IF}" -j ACCEPT
    iptables -C FORWARD -o "${WG_IF}" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD -o "${WG_IF}" -j ACCEPT

    if [[ "${PKG_MGR}" == "apt" ]]; then
        netfilter-persistent save >/dev/null 2>&1 || true
        netfilter-persistent reload >/dev/null 2>&1 || true
    fi

    ok "NAT and forwarding rules configured and persistent."
}

# ============================================================
# OpenVPN setup
# ============================================================

install_openvpn_packages() {
    need_root || return 1
    info "Installing OpenVPN + Easy-RSA + helpers..."
    pkg_update
    pkg_install ca-certificates openvpn easy-rsa openssl curl
    ok "Packages installed."
}

# ----------------------------
# AUTO-FIX: Easy-RSA CN conflict
# ----------------------------
easyrsa_sanitize_vars() {
    # Remove global CN override if present
    if [[ -f "${OVPN_EASYRSA_DIR}/vars" ]]; then
        sed -i '/EASYRSA_REQ_CN/d' "${OVPN_EASYRSA_DIR}/vars" 2>/dev/null || true
    fi
}

easyrsa_write_base_vars() {
    [[ -f "${OVPN_EASYRSA_DIR}/vars" ]] && easyrsa_sanitize_vars
    if [[ ! -f "${OVPN_EASYRSA_DIR}/vars" ]]; then
        cat > "${OVPN_EASYRSA_DIR}/vars" <<'VARS'
set_var EASYRSA_ALGO "ec"
set_var EASYRSA_DIGEST "sha256"
VARS
    fi
}

easyrsa_build_server_safe() {
    # Try once, if conflict error, auto-fix vars and retry
    local out
    out="$(EASYRSA_BATCH=1 ./easyrsa --batch build-server-full server nopass 2>&1 || true)"
    if grep -qi "Option conflict" <<< "${out}"; then
        warn "Easy-RSA CN conflict detected. Auto-fixing vars and retrying..."
        easyrsa_sanitize_vars
        EASYRSA_BATCH=1 ./easyrsa --batch build-server-full server nopass
        ok "Easy-RSA conflict auto-fixed."
    else
        # If no conflict and command actually failed for another reason, rethrow
        if ! grep -qi "generated" <<< "${out}" && [[ ! -f "pki/issued/server.crt" ]]; then
            # Run again normally to show real error
            EASYRSA_BATCH=1 ./easyrsa --batch build-server-full server nopass
        fi
    fi
}

init_easyrsa_pki() {
    need_root || return 1
    info "Preparing Easy-RSA PKI..."

    mkdir -p "${OVPN_EASYRSA_DIR}"
    cp -r /usr/share/easy-rsa/* "${OVPN_EASYRSA_DIR}/" 2>/dev/null || true

    pushd "${OVPN_EASYRSA_DIR}" >/dev/null

    easyrsa_write_base_vars
    [[ ! -d "pki" ]] && ./easyrsa init-pki

    # Build CA with branded CN only for this command (safe)
    if [[ ! -f "pki/ca.crt" ]]; then
        EASYRSA_BATCH=1 EASYRSA_REQ_CN="Bahdleen-CA" \
            ./easyrsa --batch build-ca nopass
    fi

    # Build server safely with auto-fix
    if [[ ! -f "pki/issued/server.crt" ]]; then
        easyrsa_build_server_safe
    fi

    [[ ! -f "pki/dh.pem" ]] && EASYRSA_BATCH=1 ./easyrsa --batch gen-dh
    EASYRSA_BATCH=1 ./easyrsa --batch gen-crl

    popd >/dev/null
    ok "PKI initialized."
}

install_openvpn_server_crypto() {
    need_root || return 1
    info "Generating tls-crypt key..."
    mkdir -p "${OVPN_SERVER_DIR}"

    # New syntax (no deprecated warning)
    openvpn --genkey secret "${OVPN_SERVER_DIR}/tls-crypt.key"
    ok "TLS key generated."

    info "Installing OpenVPN server keys/certs..."
    install -m 600 "${OVPN_EASYRSA_DIR}/pki/private/server.key" "${OVPN_SERVER_DIR}/server.key"
    install -m 644 "${OVPN_EASYRSA_DIR}/pki/issued/server.crt" "${OVPN_SERVER_DIR}/server.crt"
    install -m 644 "${OVPN_EASYRSA_DIR}/pki/ca.crt" "${OVPN_SERVER_DIR}/ca.crt"
    install -m 644 "${OVPN_EASYRSA_DIR}/pki/dh.pem" "${OVPN_SERVER_DIR}/dh.pem"
    install -m 644 "${OVPN_EASYRSA_DIR}/pki/crl.pem" "${OVPN_SERVER_DIR}/crl.pem"
    chmod 644 "${OVPN_SERVER_DIR}/crl.pem" 2>/dev/null || true

    ok "Server crypto installed."
}

write_openvpn_server_conf() {
    need_root || return 1
    local port="$1"
    local proto="$2"

    local dns_csv
    dns_csv="$(get_saved_dns)"
    local dns1 dns2
    dns1="$(printf '%s' "${dns_csv}" | cut -d, -f1)"
    dns2="$(printf '%s' "${dns_csv}" | cut -d, -f2)"

    info "Writing OpenVPN server config..."
    mkdir -p "${OVPN_SERVER_DIR}"

    cat > "${OVPN_SERVER_CONF}" <<EOF
port ${port}
proto ${proto}
dev tun

user nobody
group nogroup

persist-key
persist-tun

topology subnet
server ${OVPN_NET} ${OVPN_MASK}
ifconfig-pool-persist ${OVPN_SERVER_DIR}/ipp.txt

ca ${OVPN_SERVER_DIR}/ca.crt
cert ${OVPN_SERVER_DIR}/server.crt
key ${OVPN_SERVER_DIR}/server.key
dh ${OVPN_SERVER_DIR}/dh.pem
crl-verify ${OVPN_SERVER_DIR}/crl.pem

tls-crypt ${OVPN_SERVER_DIR}/tls-crypt.key

cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth SHA256

push "dhcp-option DNS ${dns1}"
EOF

    [[ -n "${dns2}" ]] && printf 'push "dhcp-option DNS %s"\n' "${dns2}" >> "${OVPN_SERVER_CONF}"

    cat >> "${OVPN_SERVER_CONF}" <<'EOF'
push "redirect-gateway def1 bypass-dhcp"

keepalive 10 120
explicit-exit-notify 1

verb 3
status /run/openvpn-server/status-server.log
EOF

    ok "Server config created."
}

start_openvpn_service() {
    need_root || return 1
    info "Starting OpenVPN service..."

    systemctl enable --now openvpn-server@server >/dev/null 2>&1 || true
    systemctl restart openvpn-server@server >/dev/null 2>&1 || true

    if systemctl is-active --quiet openvpn-server@server; then
        ok "OpenVPN service started (openvpn-server@server)."
    else
        warn "OpenVPN service did not report active yet."
        warn "Check: sudo journalctl -u openvpn-server@server -n 50 --no-pager"
    fi
}

setup_openvpn() {
    need_root || return 1

    info "Fresh setup: OpenVPN"
    static_ip_check
    choose_public_endpoint
    choose_dns

    local nat_iface
    nat_iface="$(choose_nat_iface)"
    ok "NAT interface: ${nat_iface}"

    install_openvpn_packages
    prepare_dirs

    init_easyrsa_pki
    install_openvpn_server_crypto

    local port proto
    read -r -p "OpenVPN port [${DEFAULT_OVPN_PORT}]: " port
    port="${port:-${DEFAULT_OVPN_PORT}}"
    read -r -p "Protocol udp/tcp [udp]: " proto
    proto="${proto:-udp}"

    write_openvpn_server_conf "${port}" "${proto}"
    enable_ip_forwarding
    ensure_nat_tools
    apply_nat_rules_both "${nat_iface}"

    start_openvpn_service
    ok "OpenVPN setup complete."
    pause
}

# ============================================================
# OpenVPN client management
# ============================================================

ovpn_client_template() {
    local endpoint="$1"
    local port="$2"
    local proto="$3"

    cat <<EOF
client
dev tun
proto ${proto}
remote ${endpoint} ${port}

resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server
auth SHA256
verb 3

cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM

key-direction 1
<tls-crypt>
$(cat "${OVPN_SERVER_DIR}/tls-crypt.key")
</tls-crypt>
EOF
}

add_openvpn_client() {
    need_root || return 1
    info "Add OpenVPN client"

    [[ ! -d "${OVPN_EASYRSA_DIR}/pki" ]] && {
        err "OpenVPN PKI not found. Run Setup OpenVPN first."
        pause
        return 1
    }

    local client days pass_choice
    read -r -p "Enter client username: " client
    [[ -z "${client}" ]] && { err "Client name cannot be empty."; pause; return 1; }

    read -r -p "Certificate validity in days [1080]: " days
    days="${days:-1080}"
    [[ ! "${days}" =~ ^[0-9]+$ ]] && { err "Days must be a number."; pause; return 1; }

    read -r -p "Protect client key with password? [y/N]: " pass_choice
    pass_choice="${pass_choice:-N}"

    pushd "${OVPN_EASYRSA_DIR}" >/dev/null
    export EASYRSA_CERT_EXPIRE="${days}"

    if [[ "${pass_choice}" =~ ^[Yy]$ ]]; then
        info "Easy-RSA will prompt you to set a passphrase."
        EASYRSA_BATCH=1 ./easyrsa --batch build-client-full "${client}"
    else
        EASYRSA_BATCH=1 ./easyrsa --batch build-client-full "${client}" nopass
    fi

    EASYRSA_BATCH=1 ./easyrsa --batch gen-crl
    popd >/dev/null

    install -m 644 "${OVPN_EASYRSA_DIR}/pki/crl.pem" "${OVPN_SERVER_DIR}/crl.pem"
    chmod 644 "${OVPN_SERVER_DIR}/crl.pem" 2>/dev/null || true

    local endpoint port proto
    endpoint="$(get_saved_endpoint)"
    port="$(awk '/^port /{print $2}' "${OVPN_SERVER_CONF}" 2>/dev/null || true)"
    proto="$(awk '/^proto /{print $2}' "${OVPN_SERVER_CONF}" 2>/dev/null || true)"
    port="${port:-${DEFAULT_OVPN_PORT}}"
    proto="${proto:-udp}"

    local client_dir="${OVPN_EXPORT_BASE}/${client}"
    mkdir -p "${client_dir}"
    chown -R "${RUN_USER}:${RUN_USER}" "${client_dir}" 2>/dev/null || true

    local ovpn_file="${client_dir}/${client}.ovpn"

    {
        ovpn_client_template "${endpoint}" "${port}" "${proto}"
        printf "\n<ca>\n%s\n</ca>\n" "$(cat "${OVPN_SERVER_DIR}/ca.crt")"
        printf "<cert>\n%s\n</cert>\n" \
            "$(awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' \
            "${OVPN_EASYRSA_DIR}/pki/issued/${client}.crt")"
        printf "<key>\n%s\n</key>\n" "$(cat "${OVPN_EASYRSA_DIR}/pki/private/${client}.key")"
    } > "${ovpn_file}"

    chown "${RUN_USER}:${RUN_USER}" "${ovpn_file}" 2>/dev/null || true
    chmod 600 "${ovpn_file}" 2>/dev/null || true

    ok "OpenVPN client exported:"
    printf "  %s\n" "${ovpn_file}"
    pause
}

revoke_openvpn_client() {
    need_root || return 1
    info "Revoke OpenVPN client"

    [[ ! -d "${OVPN_EASYRSA_DIR}/pki" ]] && { err "OpenVPN PKI not found."; pause; return 1; }

    local client
    read -r -p "Enter client username to revoke: " client
    [[ -z "${client}" ]] && { err "Client name cannot be empty."; pause; return 1; }

    pushd "${OVPN_EASYRSA_DIR}" >/dev/null
    EASYRSA_BATCH=1 ./easyrsa --batch revoke "${client}" || true
    EASYRSA_BATCH=1 ./easyrsa --batch gen-crl
    popd >/dev/null

    install -m 644 "${OVPN_EASYRSA_DIR}/pki/crl.pem" "${OVPN_SERVER_DIR}/crl.pem"
    chmod 644 "${OVPN_SERVER_DIR}/crl.pem" 2>/dev/null || true

    ok "Client revoked: ${client}"
    pause
}

# ============================================================
# WireGuard setup & peers
# ============================================================

install_wireguard_packages() {
    need_root || return 1
    info "Installing WireGuard..."
    pkg_update
    case "${PKG_MGR}" in
        apt) pkg_install wireguard wireguard-tools qrencode ca-certificates curl ;;
        dnf) pkg_install wireguard-tools qrencode ca-certificates curl ;;
        pacman) pkg_install wireguard-tools qrencode ca-certificates curl ;;
        zypper) pkg_install wireguard-tools qrencode ca-certificates curl ;;
        *) err "Unsupported OS for WireGuard install."; return 1 ;;
    esac
    ok "WireGuard packages installed."
}

wg_generate_server_keys() {
    need_root || return 1
    mkdir -p "${WG_DIR}"

    if [[ ! -f "${WG_DIR}/server.key" ]]; then
        umask 077
        wg genkey | tee "${WG_DIR}/server.key" | wg pubkey > "${WG_DIR}/server.pub"
        ok "WireGuard server keys ready."
    else
        ok "WireGuard server keys already exist."
    fi
}

write_wireguard_server_conf() {
    need_root || return 1
    local port="$1"
    local server_priv
    server_priv="$(cat "${WG_DIR}/server.key")"

    info "Writing WireGuard server config..."
    cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = ${port}
PrivateKey = ${server_priv}
EOF

    chmod 600 "${WG_CONF}" 2>/dev/null || true
    ok "WireGuard server config created."
}

start_wireguard_service() {
    need_root || return 1
    systemctl enable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true

    if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
        ok "WireGuard service started (wg-quick@${WG_IF})."
    else
        warn "WireGuard service not active yet."
        warn "Check: sudo journalctl -u wg-quick@${WG_IF} -n 50 --no-pager"
    fi
}

setup_wireguard() {
    need_root || return 1

    info "Fresh setup: WireGuard"
    static_ip_check
    choose_public_endpoint
    choose_dns

    local nat_iface
    nat_iface="$(choose_nat_iface)"
    ok "NAT interface: ${nat_iface}"

    install_wireguard_packages
    prepare_dirs

    wg_generate_server_keys

    local port
    read -r -p "WireGuard port [${DEFAULT_WG_PORT}]: " port
    port="${port:-${DEFAULT_WG_PORT}}"

    write_wireguard_server_conf "${port}"
    enable_ip_forwarding
    ensure_nat_tools
    apply_nat_rules_both "${nat_iface}"

    start_wireguard_service
    ok "WireGuard setup complete."
    pause
}

next_wg_ip() {
    local count
    count="$(grep -c "AllowedIPs = 10.20.0." "${WG_CONF}" 2>/dev/null || true)"
    local octet=$((count + 2))
    printf "10.20.0.%s/32\n" "${octet}"
}

add_wireguard_peer() {
    need_root || return 1
    info "Add WireGuard peer"

    [[ ! -f "${WG_CONF}" ]] && {
        err "WireGuard server config not found. Run Setup WireGuard first."
        pause
        return 1
    }

    local peer
    read -r -p "Enter peer name: " peer
    [[ -z "${peer}" ]] && { err "Peer name cannot be empty."; pause; return 1; }

    local port endpoint dns_csv
    port="$(grep -m1 "^ListenPort" "${WG_CONF}" | awk -F'=' '{gsub(/ /,"",$2); print $2}' || true)"
    port="${port:-${DEFAULT_WG_PORT}}"
    endpoint="$(get_saved_endpoint)"
    dns_csv="$(get_saved_dns)"

    local dns1 dns2
    dns1="$(printf '%s' "${dns_csv}" | cut -d, -f1)"
    dns2="$(printf '%s' "${dns_csv}" | cut -d, -f2)"

    local peer_dir="${WG_EXPORT_BASE}/${peer}"
    mkdir -p "${peer_dir}"
    chown -R "${RUN_USER}:${RUN_USER}" "${peer_dir}" 2>/dev/null || true

    umask 077
    local peer_priv peer_pub
    peer_priv="$(wg genkey)"
    peer_pub="$(printf '%s' "${peer_priv}" | wg pubkey)"

    local allowed_ip
    allowed_ip="$(next_wg_ip)"

    {
        printf "\n# peer_name: %s\n" "${peer}"
        printf "[Peer]\n"
        printf "PublicKey = %s\n" "${peer_pub}"
        printf "AllowedIPs = %s\n" "${allowed_ip}"
    } >> "${WG_CONF}"

    local server_pub
    server_pub="$(cat "${WG_DIR}/server.pub")"

    local client_ip="${allowed_ip%/32}/32"
    local client_conf="${peer_dir}/${peer}.conf"

    cat > "${client_conf}" <<EOF
[Interface]
PrivateKey = ${peer_priv}
Address = ${client_ip}
DNS = ${dns1}${dns2:+, ${dns2}}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chown "${RUN_USER}:${RUN_USER}" "${client_conf}" 2>/dev/null || true
    chmod 600 "${client_conf}" 2>/dev/null || true

    # Apply the new peer live instead of restarting the whole interface, so
    # existing connected peers aren't disconnected just to add one more.
    if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
        wg set "${WG_IF}" peer "${peer_pub}" allowed-ips "${allowed_ip}" \
            || systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    else
        systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    fi

    ok "WireGuard peer exported:"
    printf "  %s\n" "${client_conf}"

    if command -v qrencode >/dev/null 2>&1; then
        printf "\nQR (optional):\n"
        qrencode -t ansiutf8 < "${client_conf}" || true
    fi

    pause
}

remove_wireguard_peer() {
    need_root || return 1
    info "Remove WireGuard peer"

    [[ ! -f "${WG_CONF}" ]] && { err "WireGuard config not found."; pause; return 1; }

    local peer
    read -r -p "Enter peer name to remove: " peer
    [[ -z "${peer}" ]] && { err "Peer name cannot be empty."; pause; return 1; }

    if ! grep -qF "# peer_name: ${peer}" "${WG_CONF}"; then
        err "No peer named '${peer}' found in ${WG_CONF}."
        warn "Peers added before this script's update won't have a name tag;"
        warn "remove their [Peer] block manually if needed."
        pause
        return 1
    fi

    local peer_pub
    peer_pub="$(awk -v tag="# peer_name: ${peer}" '
        $0 == tag { found=1; next }
        found && /^PublicKey = / { print $3; exit }
    ' "${WG_CONF}")"

    # Drop the "# peer_name: X" comment, the following [Peer] header, and every
    # line until the next blank line or [Peer]/[Interface] section.
    awk -v tag="# peer_name: ${peer}" '
        $0 == tag { skipping=1; next }
        skipping && /^\[Peer\]/ { next }
        skipping && (/^\s*$/ || /^\[/) { skipping=0 }
        !skipping { print }
    ' "${WG_CONF}" > "${WG_CONF}.tmp" && mv "${WG_CONF}.tmp" "${WG_CONF}"
    chmod 600 "${WG_CONF}" 2>/dev/null || true

    if [[ -n "${peer_pub}" ]] && systemctl is-active --quiet "wg-quick@${WG_IF}"; then
        wg set "${WG_IF}" peer "${peer_pub}" remove \
            || systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    else
        systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    fi

    rm -rf "${WG_EXPORT_BASE:?}/${peer}" || true

    ok "Peer removed and revoked: ${peer}"
    pause
}

# ============================================================
# Combined setup
# ============================================================

setup_both() {
    need_root || return 1

    info "Fresh setup: OpenVPN + WireGuard"
    static_ip_check
    choose_public_endpoint
    choose_dns

    local nat_iface
    nat_iface="$(choose_nat_iface)"
    ok "NAT interface: ${nat_iface}"

    install_openvpn_packages
    install_wireguard_packages
    prepare_dirs

    init_easyrsa_pki
    install_openvpn_server_crypto

    local ovpn_port ovpn_proto
    read -r -p "OpenVPN port [${DEFAULT_OVPN_PORT}]: " ovpn_port
    ovpn_port="${ovpn_port:-${DEFAULT_OVPN_PORT}}"
    read -r -p "Protocol udp/tcp [udp]: " ovpn_proto
    ovpn_proto="${ovpn_proto:-udp}"

    write_openvpn_server_conf "${ovpn_port}" "${ovpn_proto}"

    wg_generate_server_keys
    local wg_port
    read -r -p "WireGuard port [${DEFAULT_WG_PORT}]: " wg_port
    wg_port="${wg_port:-${DEFAULT_WG_PORT}}"
    write_wireguard_server_conf "${wg_port}"

    enable_ip_forwarding
    ensure_nat_tools
    apply_nat_rules_both "${nat_iface}"

    start_openvpn_service
    start_wireguard_service

    ok "Both VPNs installed and configured."
    pause
}

# ============================================================
# Status / Update / Cleanup / Reset / Uninstall
# ============================================================

show_status() {
    clr
    ascii_banner

    printf "Detected OS: %s (%s)\n" "${OS_PRETTY}" "${OS_FAMILY}"
    printf "User: %s\n\n" "${RUN_USER}"

    printf "Exports:\n"
    printf "  OpenVPN:   %s\n" "${OVPN_EXPORT_BASE}"
    printf "  WireGuard: %s\n\n" "${WG_EXPORT_BASE}"

    local ovpn_connected=0 wg_peers=0
    [[ -f /run/openvpn-server/status-server.log ]] \
        && ovpn_connected="$(grep -c '^CLIENT_LIST,' /run/openvpn-server/status-server.log 2>/dev/null || echo 0)"
    wg_peers="$(wg show "${WG_IF}" peers 2>/dev/null | wc -l || echo 0)"

    printf "Services:\n"
    if systemctl is-active --quiet openvpn-server@server; then
        printf "  OpenVPN:   ${C_GREEN}active${C_RESET}   (%s connected)\n" "${ovpn_connected}"
    else
        printf "  OpenVPN:   ${C_YELLOW}inactive${C_RESET}\n"
    fi
    if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
        printf "  WireGuard: ${C_GREEN}active${C_RESET}   (%s peers configured)\n" "${wg_peers}"
    else
        printf "  WireGuard: ${C_YELLOW}inactive${C_RESET}\n"
    fi

    printf "\nEndpoint: %s\n" "$(get_saved_endpoint 2>/dev/null || echo "none")"
    printf "DNS:      %s\n" "$(get_saved_dns)"
    printf "Version:  %s\n" "${SCRIPT_VERSION}"

    pause
}

update_libraries() {
    need_root || return 1
    info "Updating libraries/packages..."
    pkg_update

    case "${PKG_MGR}" in
        apt) apt-get upgrade -y ;;
        dnf) dnf upgrade -y ;;
        pacman) pacman -Syu --noconfirm ;;
        zypper) zypper --non-interactive update ;;
        *) true ;;
    esac

    ok "Packages updated."
    pause
}

cleanup_leftovers() {
    need_root || return 1
    info "Cleanup leftovers..."

    systemctl stop openvpn-server@server >/dev/null 2>&1 || true
    systemctl disable openvpn-server@server >/dev/null 2>&1 || true
    systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true

    rm -rf "${OVPN_SERVER_DIR}" "${OVPN_EASYRSA_DIR}" >/dev/null 2>&1 || true
    rm -f "${WG_DIR}/server.key" "${WG_DIR}/server.pub" "${WG_CONF}" >/dev/null 2>&1 || true

    ok "Server leftovers removed."
    pause
}

reset_reinstall_both() {
    need_root || return 1
    info "Reset & Reinstall BOTH"
    cleanup_leftovers
    setup_both
}

uninstall_everything() {
    need_root || return 1
    info "Uninstall EVERYTHING"
    cleanup_leftovers
    pkg_remove openvpn easy-rsa wireguard wireguard-tools qrencode || true
    ok "Packages removed."
    pause
}

# ============================================================
# Global command installer
# ============================================================

install_global_command() {
    need_root || return 1

    clr
    ascii_banner
    info "Install global command: ${SCRIPT_NAME}"

    local LIB_DIR="/usr/local/lib/${SCRIPT_NAME}"
    local BIN_PATH="/usr/local/bin/${SCRIPT_NAME}"

    mkdir -p "${LIB_DIR}"
    install -m 755 "${SCRIPT_SELF}" "${LIB_DIR}/${SCRIPT_NAME}.sh"

    cat > "${BIN_PATH}" <<EOF
#!/usr/bin/env bash
exec sudo "${LIB_DIR}/${SCRIPT_NAME}.sh" "\$@"
EOF
    chmod 755 "${BIN_PATH}"

    local sudoers_file="/etc/sudoers.d/${SCRIPT_NAME}-${RUN_USER}"
    cat > "${sudoers_file}" <<EOF
${RUN_USER} ALL=(ALL) NOPASSWD: ${BIN_PATH}, ${LIB_DIR}/${SCRIPT_NAME}.sh
EOF
    chmod 440 "${sudoers_file}"

    ok "Global command installed."
    ok "You can now run: ${SCRIPT_NAME}"
    pause
}

# ============================================================
# Help
# ============================================================

show_help() {
    clr
    ascii_banner
    printf "Bahdleen VPN - OpenVPN + WireGuard\n"
    printf "Version: %s\n\n" "${SCRIPT_VERSION}"
    printf "Exports:\n"
    printf "  %s\n" "${OVPN_EXPORT_BASE}"
    printf "  %s\n\n" "${WG_EXPORT_BASE}"
    printf "After installation, the key to start is:\n"
    printf "  %s\n\n" "${SCRIPT_NAME}"
    pause
}

# ============================================================
# Menu
# ============================================================

render_menu() {
    clr
    ascii_banner

    printf "Detected OS: %s (%s)\n" "${OS_PRETTY}" "${OS_FAMILY}"
    printf "User: %s\n\n" "${RUN_USER}"

    printf "Exports:\n"
    printf "  OpenVPN:   %s\n" "${OVPN_EXPORT_BASE}"
    printf "  WireGuard: %s\n\n" "${WG_EXPORT_BASE}"

    printf "Tip: Run option 1 to enable the '%s' command for future use.\n\n" "${SCRIPT_NAME}"

    printf "1) Install global command (%s)\n" "${SCRIPT_NAME}"
    printf "2) Setup OpenVPN\n"
    printf "3) Setup WireGuard\n"
    printf "4) Setup BOTH\n"
    printf "5) Add OpenVPN client (password + expiry)\n"
    printf "6) Revoke OpenVPN client\n"
    printf "7) Add WireGuard peer\n"
    printf "8) Remove WireGuard peer\n"
    printf "9) Status\n"
    printf "10) Update libraries/packages\n"
    printf "11) Repair directories\n"
    printf "12) Cleanup leftovers\n"
    printf "13) Reset & Reinstall BOTH\n"
    printf "14) Uninstall EVERYTHING\n"
    printf "15) Help\n"
    printf "0) Exit\n\n"
}

main_loop() {
    while true; do
        render_menu
        local opt
        read -r -p "Select option: " opt

        # Every action is run with `|| true`: under `set -e`, a plain non-zero
        # return here (e.g. need_root failing when not launched via the
        # installed sudo wrapper) would otherwise silently kill the whole
        # script instead of returning to the menu.
        case "${opt}" in
            1) install_global_command || true ;;
            2) setup_openvpn || true ;;
            3) setup_wireguard || true ;;
            4) setup_both || true ;;
            5) add_openvpn_client || true ;;
            6) revoke_openvpn_client || true ;;
            7) add_wireguard_peer || true ;;
            8) remove_wireguard_peer || true ;;
            9) show_status || true ;;
            10) update_libraries || true ;;
            11) repair_dirs || true ;;
            12) cleanup_leftovers || true ;;
            13) reset_reinstall_both || true ;;
            14) uninstall_everything || true ;;
            15) show_help || true ;;
            0) exit 0 ;;
            *) warn "Invalid option."; pause ;;
        esac
    done
}

# ============================================================
# Entrypoint
# ============================================================

detect_os
prepare_dirs || true
main_loop
