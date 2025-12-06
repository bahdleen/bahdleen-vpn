# Bahdleen VPN

A unified OpenVPN + WireGuard installer and manager built for clean automation,
cross-distro support, and user-friendly client export workflows.

## Features
- OpenVPN + Easy-RSA automated PKI
- WireGuard server + peer management
- Public IP detection with manual fallback
- DNS selection for client push
- NAT interface detection + persistence
- Home-based export directories:
  - `~/ovpn-clients`
  - `~/wireguard-clients`
- Global command launcher: `bahdleen-vpn`
- Cleanup, reset, repair, and uninstall flows

## Supported Linux
- Ubuntu
- Debian
- Linux Mint
- Fedora
- Arch
- Manjaro
- openSUSE

## Quick Start
```bash
git clone https://github.com/bahdleen/bahdleen-vpn.git
cd bahdleen-vpn
chmod +x bahdleen-vpn.sh
sudo ./bahdleen-vpn.sh
