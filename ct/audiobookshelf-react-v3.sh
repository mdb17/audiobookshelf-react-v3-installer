#!/usr/bin/env bash
# Community Scripts-style Audiobookshelf React/v3 test LXC.
# This is a separate test variant; it never changes CT102.

_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

# Copyright (c) 2021-2026 tteck / community-scripts contributors
# License: MIT (Community Scripts conventions and shared engine)
# Source: https://github.com/audiobookshelf/audiobookshelf-client-react

APP="Audiobookshelf React V3"
var_tags="${var_tags:-audiobookshelf;test;react}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-1}"
var_keyctl="${var_keyctl:-1}"

MEDIA_SOURCE="/mnt/pve/media"
BACKUPS_SOURCE="/mnt/pve/backups-abs"

header_info "$APP"

for source_dir in "$MEDIA_SOURCE" "$BACKUPS_SOURCE"; do
  if [[ ! -d "$source_dir" ]]; then
    msg_error "Required host directory is missing: $source_dir"
    exit 1
  fi
done

variables
color
catch_errors

# Community Scripts validates availability itself. Keep CT102 explicitly out of
# scope even if it was supplied via the advanced wizard or an environment value.
if [[ "${CTID:-}" == "102" ]]; then
  msg_error "CT102 is protected. Choose a different CTID for this test instance."
  exit 1
fi

# The engine builds PCT_OPTIONS immediately before it calls _pct_create. Wrap
# that narrow creation primitive so both bind mounts exist before the first LXC
# start and before the Docker container is launched. The wrapper also applies to
# the engine's safe retry paths.
eval "$(declare -f _pct_create | sed '1s/_pct_create/_abs_react_v3_pct_create/')"
_pct_create() {
  _abs_react_v3_pct_create "$@" \
    --mp0 "${MEDIA_SOURCE},mp=/media,ro=1" \
    --mp1 "${BACKUPS_SOURCE},mp=/backups,ro=1"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if ! command -v docker >/dev/null 2>&1; then
    msg_error "No Docker installation found for ${APP}."
    exit 1
  fi

  msg_info "Updating Audiobookshelf React/v3 image"
  docker pull ghcr.io/advplyr/audiobookshelf:v3
  docker rm -f audiobookshelf-react-v3-test >/dev/null 2>&1 || true
  docker run -d --name audiobookshelf-react-v3-test --restart unless-stopped \
    -p 13378:80 \
    -e "TZ=${TZ:-Etc/UTC}" \
    -v /opt/audiobookshelf-react-v3/config:/config \
    -v /opt/audiobookshelf-react-v3/metadata:/metadata \
    -v /media:/media:ro \
    -v /backups:/backups:ro \
    ghcr.io/advplyr/audiobookshelf:v3
  msg_ok "Updated Audiobookshelf React/v3"
  exit 0
}

start
build_container
description
msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} test instance is ready.${CL}"
echo -e "${INFO}${YW}Access it using:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:13378${CL}"
echo -e "${INFO}${YW}Host mounts: ${MEDIA_SOURCE} → /media (read-only); ${BACKUPS_SOURCE} → /backups (read-only).${CL}"
