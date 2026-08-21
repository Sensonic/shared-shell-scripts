#!/usr/bin/env bash
set -euo pipefail

# =========================
# Defaults (can be overridden via arguments)
# =========================
WG_SERVER_PORT="49830"
WG_NETWORK_CIDR="11.0.0.0/24"
AUTO_START_WG="true"

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
PRIVATE_KEY_FILE="${WG_DIR}/private.key"
PUBLIC_KEY_FILE="${WG_DIR}/public.key"

# =========================
# Help function
# =========================
show_help() {
  cat <<EOF
WireGuard Client Setup Script

Usage:
  sudo bash $0 --server-ip <IP> --server-key <PUBKEY> --client-ip <IP> [OPTIONS]
  sudo bash $0 clean
  sudo bash $0 -h|--help

Required arguments:
  --server-ip <IP>      WireGuard hub server public IP address
  --server-key <KEY>    WireGuard hub server public key
  --client-ip <IP>      This client's WireGuard IP (e.g., 10.0.0.2)

Optional arguments:
  --port <PORT>         WireGuard server port (default: ${WG_SERVER_PORT})
  --cidr <CIDR>         WireGuard network CIDR (default: ${WG_NETWORK_CIDR})
  --no-autostart        Do not automatically start WireGuard after setup
  -h, --help            Show this help message

Commands:
  clean                 Remove WireGuard client configuration files (with confirmation)

Examples:
  # Setup client with required parameters
  sudo bash $0 --server-ip 13.205.228.162 --server-key "6BJYOH2FJqxDjPiDNkPDzK8q2/Rga/zCGm93HQwcUzU=" --client-ip 10.0.0.2

  # Setup with custom port and CIDR
  sudo bash $0 --server-ip 13.205.228.162 --server-key "6BJYOH2FJqxDjPiDNkPDzK8q2/Rga/zCGm93HQwcUzU=" --client-ip 10.0.0.2 --port 46930 --cidr 10.0.0.0/27

  # Remove client configuration
  sudo bash $0 clean

EOF
  exit 0
}

# =========================
# Clean function
# =========================
do_clean() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: Please run as root: sudo bash $0 clean"
    exit 1
  fi

  echo "The following WireGuard client files will be removed:"
  echo ""

  local files_to_remove=()
  [[ -f "${WG_CONF}" ]] && files_to_remove+=("${WG_CONF}")
  [[ -f "${PRIVATE_KEY_FILE}" ]] && files_to_remove+=("${PRIVATE_KEY_FILE}")
  [[ -f "${PUBLIC_KEY_FILE}" ]] && files_to_remove+=("${PUBLIC_KEY_FILE}")

  if [[ ${#files_to_remove[@]} -eq 0 ]]; then
    echo "  No WireGuard configuration files found."
    exit 0
  fi

  for f in "${files_to_remove[@]}"; do
    echo "  - ${f}"
  done
  echo ""

  if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    echo "The wg-quick@wg0 service is currently RUNNING and will be stopped."
  fi
  if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
    echo "The wg-quick@wg0 service is ENABLED and will be disabled."
  fi
  echo ""

  read -rp "Are you sure you want to proceed? [y/N]: " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  echo ""
  if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    echo "Stopping wg-quick@wg0..."
    systemctl stop wg-quick@wg0
  fi
  if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
    echo "Disabling wg-quick@wg0..."
    systemctl disable wg-quick@wg0
  fi

  for f in "${files_to_remove[@]}"; do
    echo "Removing ${f}..."
    rm -f "${f}"
  done

  echo ""
  echo "✅ WireGuard client configuration cleaned."
  exit 0
}

# =========================
# Validate IPv4 function
# =========================
validate_ipv4() {
  local ip="$1"
  local allow_cidr="${2:-false}"

  if [[ "${allow_cidr}" == "false" && "${ip}" == */* ]]; then
    echo "Error: CIDR notation not allowed. Provide plain IPv4 only (e.g., 10.0.0.2)."
    return 1
  fi

  local plain_ip="${ip%/*}"
  if [[ ! "${plain_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IPv4 format '${ip}'."
    return 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<< "${plain_ip}"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    if (( octet < 0 || octet > 255 )); then
      echo "Error: Invalid IPv4 value '${ip}'."
      return 1
    fi
  done
  return 0
}

# =========================
# Validate private IPv4
# =========================
validate_private_ipv4() {
  local ip="$1"
  local plain_ip="${ip%/*}"

  IFS='.' read -r o1 o2 o3 o4 <<< "${plain_ip}"
  if ! {
    (( o1 == 10 )) ||
    (( o1 == 172 && o2 >= 16 && o2 <= 31 )) ||
    (( o1 == 192 && o2 == 168 ));
  }; then
    echo "Error: '${plain_ip}' is not a private (RFC1918) IPv4 address."
    return 1
  fi
  return 0
}

# =========================
# Parse arguments
# =========================
WG_SERVER_PUBLIC_IP=""
WG_SERVER_PUBLIC_KEY=""
CLIENT_INPUT=""

if [[ $# -eq 0 ]]; then
  show_help
fi

# Check for help or clean first
case "${1:-}" in
  -h|--help)
    show_help
    ;;
  clean)
    do_clean
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    --server-ip)
      WG_SERVER_PUBLIC_IP="$2"
      shift 2
      ;;
    --server-key)
      WG_SERVER_PUBLIC_KEY="$2"
      shift 2
      ;;
    --client-ip)
      CLIENT_INPUT="$2"
      shift 2
      ;;
    --port)
      WG_SERVER_PORT="$2"
      shift 2
      ;;
    --cidr)
      WG_NETWORK_CIDR="$2"
      shift 2
      ;;
    --no-autostart)
      AUTO_START_WG="false"
      shift
      ;;
    *)
      echo "Error: Unknown argument '$1'"
      echo "Use -h or --help for usage information."
      exit 1
      ;;
  esac
done

# =========================
# Validate required arguments
# =========================
MISSING_ARGS=()
[[ -z "${WG_SERVER_PUBLIC_IP}" ]] && MISSING_ARGS+=("--server-ip")
[[ -z "${WG_SERVER_PUBLIC_KEY}" ]] && MISSING_ARGS+=("--server-key")
[[ -z "${CLIENT_INPUT}" ]] && MISSING_ARGS+=("--client-ip")

if [[ ${#MISSING_ARGS[@]} -gt 0 ]]; then
  echo "Error: Missing required argument(s): ${MISSING_ARGS[*]}"
  echo ""
  echo "Use -h or --help for usage information."
  exit 1
fi

# Validate server IP
if ! validate_ipv4 "${WG_SERVER_PUBLIC_IP}" "false"; then
  exit 1
fi

# Validate client IP
if ! validate_ipv4 "${CLIENT_INPUT}" "false"; then
  exit 1
fi

# Validate client IP is private
if ! validate_private_ipv4 "${CLIENT_INPUT}"; then
  exit 1
fi

# Validate CIDR format
if ! validate_ipv4 "${WG_NETWORK_CIDR}" "true"; then
  exit 1
fi

# Validate port
if ! [[ "${WG_SERVER_PORT}" =~ ^[0-9]+$ ]] || (( WG_SERVER_PORT < 1 || WG_SERVER_PORT > 65535 )); then
  echo "Error: Invalid port '${WG_SERVER_PORT}'. Must be 1-65535."
  exit 1
fi

# =========================
# Setup variables
# =========================
CLIENT_ADDRESS="${CLIENT_INPUT}/32"
CLIENT_IP="${CLIENT_ADDRESS%/*}"

# =========================
# Root check
# =========================
if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0 --server-ip ... --server-key ... --client-ip ..."
  exit 1
fi

# =========================
# Install WireGuard if needed
# =========================
if command -v wg >/dev/null 2>&1; then
  echo "WireGuard already installed. Skipping apt-get update/install."
else
  echo "Installing WireGuard..."
  apt-get update -y
  apt-get install -y wireguard
fi

mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"

# =========================
# Generate keys if not exist
# =========================
KEYS_GENERATED="false"
if [[ ! -f "${PRIVATE_KEY_FILE}" || ! -f "${PUBLIC_KEY_FILE}" ]]; then
  echo "Generating WireGuard key pair..."
  umask 077
  wg genkey | tee "${PRIVATE_KEY_FILE}" | wg pubkey > "${PUBLIC_KEY_FILE}"
  KEYS_GENERATED="true"
else
  echo "Using existing WireGuard key pair."
fi

CLIENT_PRIVATE_KEY="$(cat "${PRIVATE_KEY_FILE}")"
CLIENT_PUBLIC_KEY="$(cat "${PUBLIC_KEY_FILE}")"

# =========================
# Generate config (idempotent)
# =========================
NEW_CONF="$(mktemp)"
cat > "${NEW_CONF}" <<EOF
[Interface]
Address = ${CLIENT_ADDRESS}
PrivateKey = ${CLIENT_PRIVATE_KEY}

[Peer]
PublicKey = ${WG_SERVER_PUBLIC_KEY}
Endpoint = ${WG_SERVER_PUBLIC_IP}:${WG_SERVER_PORT}
AllowedIPs = ${WG_NETWORK_CIDR}
PersistentKeepalive = 25
EOF

CONFIG_CHANGED="false"
if [[ ! -f "${WG_CONF}" ]] || ! cmp -s "${NEW_CONF}" "${WG_CONF}"; then
  install -m 600 "${NEW_CONF}" "${WG_CONF}"
  CONFIG_CHANGED="true"
  echo "Updated ${WG_CONF}."
else
  echo "${WG_CONF} already up to date."
fi
rm -f "${NEW_CONF}"

# =========================
# Enable and start WireGuard service
# =========================
systemctl enable wg-quick@wg0

if [[ "${AUTO_START_WG}" == "true" ]]; then
  if systemctl is-active --quiet wg-quick@wg0; then
    if [[ "${CONFIG_CHANGED}" == "true" ]]; then
      echo "Restarting wg-quick@wg0 due to config change..."
      systemctl restart wg-quick@wg0
    else
      echo "wg-quick@wg0 already running; no restart needed."
    fi
  else
    echo "Starting wg-quick@wg0..."
    systemctl start wg-quick@wg0
  fi
fi

# =========================
# Output summary
# =========================
echo ""
echo "✅ Client configured"
echo "   Address : ${CLIENT_ADDRESS}"
echo "   Config  : ${WG_CONF}"
echo "   Server  : ${WG_SERVER_PUBLIC_IP}:${WG_SERVER_PORT}"
echo "   Network : ${WG_NETWORK_CIDR}"
[[ "${KEYS_GENERATED}" == "true" ]] && echo "   Keys    : Newly generated"
echo ""
echo "===== CLIENT PUBLIC KEY (paste into server config) ====="
echo "${CLIENT_PUBLIC_KEY}"
echo ""
echo "===== SERVER PEER BLOCK (paste into server /etc/wireguard/wg0.conf) ====="
echo "[Peer]"
echo "# ${CLIENT_IP}"
echo "PublicKey = ${CLIENT_PUBLIC_KEY}"
echo "AllowedIPs = ${CLIENT_ADDRESS}"
echo ""
