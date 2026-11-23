#!/usr/bin/env bash
# Audiobookshelf React/v3 test LXC for Proxmox VE
# Creates a NEW container only.  It never changes CT102 or its filesystem.
# Source: official image ghcr.io/advplyr/audiobookshelf:v3

set -Eeuo pipefail

APP_NAME="Audiobookshelf React/v3 test"
IMAGE_REPOSITORY="ghcr.io/advplyr/audiobookshelf"
MEDIA_SOURCE="/mnt/pve/media"
BACKUPS_SOURCE="/mnt/pve/backups-abs"
MEDIA_TARGET="/media"
BACKUPS_TARGET="/backups"

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m%s\033[0m\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }
ask() { local prompt="$1" default="$2" reply; read -r -p "$prompt [$default]: " reply; printf '%s' "${reply:-$default}"; }
require_root() { [[ ${EUID} -eq 0 ]] || die "Run this script as root on the Proxmox host."; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

cleanup_failed_ct() {
  local status=$?
  if [[ $status -ne 0 && ${CT_CREATED:-0} -eq 1 ]]; then
    yellow "The new CT ${CTID} was created but setup did not finish. It was left stopped for inspection."
    yellow "It is safe to remove only that new CT with: pct destroy ${CTID}"
  fi
  exit "$status"
}
trap cleanup_failed_ct EXIT

check_ctid_unused() {
  [[ "$1" =~ ^[1-9][0-9]{1,5}$ ]] || die "CTID must be a positive numeric container ID."
  [[ "$1" != "102" ]] || die "CT102 is explicitly protected; choose another CTID."
  ! pct status "$1" >/dev/null 2>&1 || die "CTID $1 is already in use."
  [[ ! -e "/etc/pve/lxc/$1.conf" ]] || die "Configuration already exists for CTID $1."
}

validate_ipv4_cidr() {
  local value="$1" ip prefix octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  ip=${value%/*}
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do ((octet >= 0 && octet <= 255)) || return 1; done
}

check_static_ip_unused() {
  local cidr="$1" ip=${cidr%/*}
  if grep -RqsE "(^|,)ip=${ip}/|ip=${ip}/" /etc/pve/lxc 2>/dev/null; then
    die "IP address $ip is already declared in a local LXC configuration."
  fi
  # A reply is a hard stop. No reply is only a best-effort check; static-IP
  # allocation remains the administrator's responsibility.
  if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
    die "IP address $ip replied to ping and is therefore not safe to use."
  fi
  if ip neigh show to "$ip" 2>/dev/null | grep -qE 'lladdr|REACHABLE|STALE|DELAY|PROBE'; then
    die "IP address $ip has a neighbor-table entry and is not safe to use."
  fi
  yellow "No Proxmox LXC configuration, ping reply, or neighbor entry claims $ip. Confirm it is also outside DHCP reservations."
}

main() {
  require_root
  require_command pct
  require_command pveam
  require_command pvesm
  require_command pvesh
  require_command pveversion
  require_command awk
  require_command dpkg

  pveversion -v >/dev/null 2>&1 || die "This host does not appear to be Proxmox VE."
  [[ -d "$MEDIA_SOURCE" ]] || die "Required host directory is missing: $MEDIA_SOURCE"
  [[ -d "$BACKUPS_SOURCE" ]] || die "Required host directory is missing: $BACKUPS_SOURCE"

  clear 2>/dev/null || true
  info "${APP_NAME} — separate Proxmox LXC installer"
  printf '%s\n' "This creates one NEW Debian 12 LXC and never modifies CT102."
  printf '%s\n\n' "Bind mounts will be exactly: ${MEDIA_SOURCE} → ${MEDIA_TARGET} (read-only), ${BACKUPS_SOURCE} → ${BACKUPS_TARGET} (read-only)."

  local next_ctid
  next_ctid=$(pvesh get /cluster/nextid 2>/dev/null || true)
  CTID=$(ask "Container ID (CT102 is protected)" "${next_ctid:-103}")
  check_ctid_unused "$CTID"
  HOSTNAME=$(ask "Container hostname" "abs-react-v3-test")
  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Hostname contains unsupported characters."
  STORAGE=$(ask "Proxmox storage for the LXC root disk" "local-lvm")
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage '$STORAGE' is unavailable."
  TEMPLATE_STORAGE=$(ask "Storage for the Debian LXC template" "local")
  pvesm status --storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Template storage '$TEMPLATE_STORAGE' is unavailable."
  DISK_GB=$(ask "Root-disk size in GiB" "16")
  MEMORY_MB=$(ask "Memory in MiB" "2048")
  CORES=$(ask "CPU cores" "2")
  [[ "$DISK_GB" =~ ^[1-9][0-9]*$ && "$MEMORY_MB" =~ ^[2-9][0-9]{2,}$ && "$CORES" =~ ^[1-9][0-9]*$ ]] || die "Disk, memory, and CPU values must be sensible positive integers."
  BRIDGE=$(ask "Network bridge" "vmbr0")
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge '$BRIDGE' was not found."
  IP_CONFIG=$(ask "IPv4 address/CIDR, or dhcp" "dhcp")
  local NET0 GATEWAY=""
  if [[ "$IP_CONFIG" == "dhcp" ]]; then
    NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  else
    validate_ipv4_cidr "$IP_CONFIG" || die "Use IPv4/CIDR (for example 192.168.1.250/24), or dhcp."
    check_static_ip_unused "$IP_CONFIG"
    GATEWAY=$(ask "IPv4 gateway" "")
    [[ -n "$GATEWAY" ]] || die "A gateway is required for a static IPv4 setup."
    NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},gw=${GATEWAY}"
  fi
  TIMEZONE=$(ask "Timezone" "Etc/UTC")
  IMAGE_TAG=$(ask "Official Audiobookshelf image tag" "v3")
  [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "Image tag contains unsupported characters."

  printf '\nPlanned container:\n'
  printf '  CTID/hostname: %s / %s\n  Disk/RAM/CPU: %s GiB / %s MiB / %s cores\n  Network: %s\n  Image: %s:%s\n' "$CTID" "$HOSTNAME" "$DISK_GB" "$MEMORY_MB" "$CORES" "$NET0" "$IMAGE_REPOSITORY" "$IMAGE_TAG"
  printf '  Read-only mounts: %s → %s; %s → %s\n' "$MEDIA_SOURCE" "$MEDIA_TARGET" "$BACKUPS_SOURCE" "$BACKUPS_TARGET"
  read -r -p "Create this new test LXC now? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]] || { info "Cancelled; nothing was changed."; exit 0; }

  info "Finding the current Debian 12 LXC template…"
  pveam update
  local template host_arch
  host_arch=$(dpkg --print-architecture)
  [[ "$host_arch" == "amd64" || "$host_arch" == "arm64" ]] || die "The official v3 image supports amd64 and arm64 only; this host reports '$host_arch'."
  template=$(pveam available --section system | awk -v arch="$host_arch" '$2 ~ ("^debian-12-standard_.*_" arch "\\.tar\\.zst$") {print $2; exit}')
  [[ -n "$template" ]] || die "No Debian 12 $host_arch template was found in the configured repositories."
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -Fxq "$TEMPLATE_STORAGE:vztmpl/$template"; then
    pveam download "$TEMPLATE_STORAGE" "$template"
  fi

  info "Creating the new unprivileged LXC…"
  pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$template" \
    --hostname "$HOSTNAME" --storage "$STORAGE" --rootfs "${STORAGE}:${DISK_GB}" \
    --cores "$CORES" --memory "$MEMORY_MB" --swap 512 --net0 "$NET0" \
    --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --start 0
  CT_CREATED=1
  pct set "$CTID" --mp0 "$MEDIA_SOURCE,mp=$MEDIA_TARGET,ro=1"
  pct set "$CTID" --mp1 "$BACKUPS_SOURCE,mp=$BACKUPS_TARGET,ro=1"

  info "Starting CT $CTID and installing Docker plus the official v3 image…"
  pct start "$CTID"
  pct exec "$CTID" -- bash -s -- "$IMAGE_REPOSITORY" "$IMAGE_TAG" "$TIMEZONE" <<'CONTAINER_SETUP'
set -Eeuo pipefail
IMAGE_REPOSITORY=$1
IMAGE_TAG=$2
TIMEZONE=$3
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates docker.io
systemctl enable --now docker
install -d -m 0750 /opt/audiobookshelf-react-v3/config /opt/audiobookshelf-react-v3/metadata
docker rm -f audiobookshelf-react-v3-test >/dev/null 2>&1 || true
docker pull "${IMAGE_REPOSITORY}:${IMAGE_TAG}"
docker run -d --name audiobookshelf-react-v3-test --restart unless-stopped \
  -p 13378:80 \
  -e "TZ=${TIMEZONE}" \
  -v /opt/audiobookshelf-react-v3/config:/config \
  -v /opt/audiobookshelf-react-v3/metadata:/metadata \
  -v /media:/media:ro \
  -v /backups:/backups:ro \
  "${IMAGE_REPOSITORY}:${IMAGE_TAG}"
CONTAINER_SETUP

  local access_ip
  if [[ "$IP_CONFIG" == "dhcp" ]]; then
    access_ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  else
    access_ip=${IP_CONFIG%/*}
  fi
  green "Installation completed. CT102 was not touched."
  printf '\nAccess Audiobookshelf at: http://%s:13378\n' "${access_ip:-<container-IP>}"
  printf '%s\n' "Inside the new CT: docker logs audiobookshelf-react-v3-test"
  printf '%s\n' "Persistent test data: /opt/audiobookshelf-react-v3/{config,metadata} inside CT $CTID"
  printf '%s\n' "The requested /backups mount is read-only, so do not choose it as an ABS backup-write destination."
}

main "$@"
