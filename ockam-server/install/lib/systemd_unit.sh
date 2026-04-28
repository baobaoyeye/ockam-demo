#!/usr/bin/env bash
# Render and install the two systemd units. If systemd not available
# (e.g. inside a non-systemd container), just write the unit files for
# reference and tell the operator how to start things by hand.

write_systemd_units() {
  local templates_dir="$1"
  local install_dir="${2:-/etc/systemd/system}"

  mkdir -p "${install_dir}"

  # ockam-server.service
  sed \
    -e "s|@OCKAM_BINARY@|/usr/local/bin/ockam|g" \
    -e "s|@OCKAM_NODE_NAME@|provider|g" \
    -e "s|@OCKAM_NODE_TRANSPORT@|0.0.0.0:14000|g" \
    -e "s|@OCKAM_HOME@|/var/lib/ockam-server|g" \
    "${templates_dir}/ockam-server.service.tpl" \
    > "${install_dir}/ockam-server.service"

  # ockam-controller.service
  sed \
    -e "s|@PYTHON@|/usr/bin/python3|g" \
    -e "s|@OCKAM_HOME@|/var/lib/ockam-server|g" \
    -e "s|@OCKAM_BINARY@|/usr/local/bin/ockam|g" \
    -e "s|@OCKAM_CONTROLLER_STATE@|/var/lib/ockam-controller/state.yaml|g" \
    -e "s|@OCKAM_NODE_NAME@|provider|g" \
    -e "s|@OCKAM_NODE_TRANSPORT@|0.0.0.0:14000|g" \
    "${templates_dir}/ockam-controller.service.tpl" \
    > "${install_dir}/ockam-controller.service"

  echo "[systemd] wrote ${install_dir}/ockam-server.service"
  echo "[systemd] wrote ${install_dir}/ockam-controller.service"
}

systemd_active() {
  [[ -d /run/systemd/system ]]
}

start_units() {
  if ! systemd_active; then
    cat <<EOM
[systemd] systemd not available in this environment.
[systemd] To start manually:
  runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \\
    /usr/local/bin/ockam node create provider \\
    --tcp-listener-address 0.0.0.0:14000 --foreground &
  runuser -u ockam -- env OCKAM_CONTROLLER_STATE=/var/lib/ockam-controller/state.yaml \\
    OCKAM_CONTROLLER_TRUST_ALL=1 \\
    /usr/bin/python3 -m ockam_controller --bind 127.0.0.1:8080 &
EOM
    return 0
  fi
  systemctl daemon-reload
  systemctl enable --now ockam-server.service
  systemctl enable --now ockam-controller.service
  systemctl status --no-pager ockam-server ockam-controller || true
}
