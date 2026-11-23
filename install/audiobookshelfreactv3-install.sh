#!/usr/bin/env bash
# Installer phase for ct/audiobookshelf-react-v3.sh.

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Docker"
$STD apt-get install -y --no-install-recommends ca-certificates docker.io
systemctl enable --now docker
msg_ok "Installed Docker"

install -d -m 0750 /opt/audiobookshelf-react-v3/config /opt/audiobookshelf-react-v3/metadata

msg_info "Pulling official Audiobookshelf React/v3 image"
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
msg_ok "Started Audiobookshelf React/v3 test container"

motd_ssh
customize
cleanup_lxc
