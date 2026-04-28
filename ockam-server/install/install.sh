#!/usr/bin/env bash
#
# install.sh — install the Ockam server (ockam node + ockam-controller) on a
# Linux host. Supports CentOS/RHEL/Rocky/Ubuntu/Debian/openEuler, x86_64 + aarch64.
#
# Usage:
#   sudo ./install.sh [--admin-identifier I_xxx,I_yyy]
#                     [--offline /path/to/bundle.tgz]
#                     [--ockam-version 0.157.0]
#                     [--no-firewall]
#                     [--no-systemd]
#
set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
TPL_DIR="$(cd "$(dirname "$0")/templates" && pwd)"
CONTROLLER_DIR="$(cd "$(dirname "$0")/../controller" && pwd)"

# shellcheck source=/dev/null
. "${LIB_DIR}/detect_os.sh"
# shellcheck source=/dev/null
. "${LIB_DIR}/deps.sh"
# shellcheck source=/dev/null
. "${LIB_DIR}/download_ockam.sh"
# shellcheck source=/dev/null
. "${LIB_DIR}/systemd_unit.sh"
# shellcheck source=/dev/null
. "${LIB_DIR}/firewall.sh"
# shellcheck source=/dev/null
. "${LIB_DIR}/healthcheck.sh"

ADMIN_IDS=""
OFFLINE_PACK=""
NO_FIREWALL=0
NO_SYSTEMD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-identifier|--admin-identifiers) ADMIN_IDS="$2"; shift 2 ;;
    --offline)        OFFLINE_PACK="$2"; shift 2 ;;
    --ockam-version)  export OCKAM_VERSION="$2"; shift 2 ;;
    --no-firewall)    NO_FIREWALL=1; shift ;;
    --no-systemd)     NO_SYSTEMD=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || { echo "[install] must run as root" >&2; exit 1; }

# 1) Detect OS
detect_os
echo "[env] OS=${OS_NAME}  family=${OS_FAMILY}  pkg=${PKG_MANAGER}  arch=${ARCH}"

# 2) Port 14000 free?
if command -v ss >/dev/null && ss -tlnp 2>/dev/null | grep -q ":14000\b"; then
  echo "[env] tcp/14000 already in use:" >&2
  ss -tlnp | grep ":14000\b" >&2
  exit 1
fi

# 3) Install OS deps
install_deps

# 4) Ockam binary
download_ockam "${OFFLINE_PACK}"

# 5) Controller (pip install in /opt/venv) — use python-ockam-host (3.10+ if avail)
PY_HOST=/usr/local/bin/python-ockam-host
[[ -x "${PY_HOST}" ]] || PY_HOST=$(command -v python3)
echo "[install] creating /opt/venv with $(${PY_HOST} --version 2>&1)"
"${PY_HOST}" -m venv /opt/venv
/opt/venv/bin/pip install --upgrade pip --quiet
if [[ -n "${OFFLINE_PACK}" && -d "${OFFLINE_PACK%.tgz}/wheels" ]]; then
  /opt/venv/bin/pip install --no-index --find-links "${OFFLINE_PACK%.tgz}/wheels" \
       ockam-controller --quiet
else
  /opt/venv/bin/pip install "${CONTROLLER_DIR}" --quiet
fi
ln -sf /opt/venv/bin/python /usr/local/bin/python-ockam

# 6) User + dirs
NOLOGIN_SHELL=/usr/sbin/nologin
[[ -x "${NOLOGIN_SHELL}" ]] || NOLOGIN_SHELL=/sbin/nologin
[[ -x "${NOLOGIN_SHELL}" ]] || NOLOGIN_SHELL=/bin/false
id ockam >/dev/null 2>&1 || useradd -r -d /var/lib/ockam-server -s "${NOLOGIN_SHELL}" ockam
mkdir -p /var/lib/ockam-server /var/lib/ockam-controller /var/log/ockam /etc/ockam-server
chown -R ockam:ockam /var/lib/ockam-server /var/lib/ockam-controller /var/log/ockam /etc/ockam-server
cp "${TPL_DIR}/server.yaml.example" /etc/ockam-server/server.yaml.example

# 7) Bootstrap admin identity if not yet present
if [[ ! -f /var/lib/ockam-server/admin/identifier ]]; then
  echo "[bootstrap] creating provider identity"
  mkdir -p /var/lib/ockam-server/admin
  chown ockam:ockam /var/lib/ockam-server/admin
  if ! runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
        /usr/local/bin/ockam identity show --output json >/dev/null 2>&1; then
    runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
        /usr/local/bin/ockam identity create default >/dev/null
  fi
  IDENT=$(runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
            /usr/local/bin/ockam identity show --output json | jq -r .identifier)
  echo "${IDENT}" > /var/lib/ockam-server/admin/identifier
  chown ockam:ockam /var/lib/ockam-server/admin/identifier
  chmod 0600 /var/lib/ockam-server/admin/identifier
fi
PROVIDER_ID=$(cat /var/lib/ockam-server/admin/identifier)

# 8) Seed controller state with admin identifiers + controller outlet
runuser -u ockam -- env OCKAM_CONTROLLER_STATE=/var/lib/ockam-controller/state.yaml \
  /opt/venv/bin/python -m ockam_controller.bootstrap \
  --state /var/lib/ockam-controller/state.yaml \
  --admin-identifiers "${ADMIN_IDS}" || true

# Persist ADMIN_IDENTIFIERS for systemd unit
sed -i.bak \
  -e "/^Environment=OCKAM_CONTROLLER_TRUST_ALL=/a Environment=OCKAM_CONTROLLER_ADMIN_IDENTIFIERS=${ADMIN_IDS}" \
  /etc/systemd/system/ockam-controller.service 2>/dev/null || true

# 9) Systemd
if [[ "${NO_SYSTEMD}" -ne 1 ]]; then
  write_systemd_units "${TPL_DIR}"
fi

# 10) Firewall
if [[ "${NO_FIREWALL}" -ne 1 ]]; then
  open_port_14000 || true
fi

# 11) Install ockam-srv management CLI
install -m 0755 "$(dirname "$0")/bin/ockam-srv" /usr/local/bin/ockam-srv

# 12) Start
if [[ "${NO_SYSTEMD}" -ne 1 ]]; then
  start_units || true
fi

# 13) Healthcheck (allow some startup time)
if systemd_active; then
  for _ in 1 2 3 4 5; do
    sleep 2
    curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break
  done
  healthcheck || true
fi

cat <<EOM

============================================================================
[install] DONE.

  ockam binary:        /usr/local/bin/ockam ($("${1:-/usr/local/bin/ockam}" --version 2>/dev/null | head -1 || echo unknown))
  controller venv:     /opt/venv
  state file:          /var/lib/ockam-controller/state.yaml
  identity vault:      /var/lib/ockam-server
  log directory:       /var/log/ockam
  systemd units:       /etc/systemd/system/ockam-{server,controller}.service
  management CLI:      /usr/local/bin/ockam-srv

  PROVIDER IDENTIFIER (give to your SDK developers):
    ${PROVIDER_ID}

  EXTERNAL PORT EXPOSED: 14000/tcp (Ockam transport — Noise XX encrypted)
  Controller is on 127.0.0.1:8080 INSIDE the host only.

NEXT:
  ockam-srv status                # see component states
  ockam-srv add-admin <I_xxx>     # whitelist a new admin identifier
  ockam-srv show-admin            # print provider identifier
  ockam-srv reload                # reload state.yaml
  ockam-srv uninstall             # tear down cleanly
============================================================================
EOM
