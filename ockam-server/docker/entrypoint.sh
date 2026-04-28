#!/usr/bin/env bash
#
# Mode A entrypoint:
#   1. On first boot, create the provider's ockam identity and persist it
#      under /var/lib/ockam-server/admin/ for the operator to docker-cp out.
#   2. Seed state.yaml with the controller outlet (allow = $ADMIN_IDENTIFIERS
#      env, comma-separated; defaults to deny-all).
#   3. Hand control to supervisord which runs:
#        - ockam node create provider --tcp-listener-address 0.0.0.0:14000 --foreground
#        - ockam-controller --bind 127.0.0.1:8080
#      Both run as the ockam user, OCKAM_HOME is /var/lib/ockam-server.
#
set -euo pipefail

ADMIN_DIR=/var/lib/ockam-server/admin
ADMIN_FILE="${ADMIN_DIR}/identifier"
STATE_FILE=${OCKAM_CONTROLLER_STATE}

# Run as the ockam user from here on — chown anything that may have been
# created by the container's image build under root.
chown -R ockam:ockam /var/lib/ockam-server /var/lib/ockam-controller /var/log/ockam

if [[ ! -f "${ADMIN_FILE}" ]]; then
  echo "[entrypoint] first boot: creating provider identity"
  mkdir -p "${ADMIN_DIR}"
  chown ockam:ockam "${ADMIN_DIR}"
  # Generate the default identity in OCKAM_HOME (=/var/lib/ockam-server)
  if ! runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
        /usr/local/bin/ockam identity show --output json >/dev/null 2>&1; then
    runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
        /usr/local/bin/ockam identity create default >/dev/null
  fi
  IDENT=$(runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
            /usr/local/bin/ockam identity show --output json | jq -r .identifier)
  echo "${IDENT}" > "${ADMIN_FILE}"
  chown ockam:ockam "${ADMIN_FILE}"
  chmod 0600 "${ADMIN_FILE}"
  cat <<EOM

============================================================================
[bootstrap] provider identifier created and saved.

  identifier file:  /var/lib/ockam-server/admin/identifier
  identifier value: ${IDENT}

NEXT STEPS:
  1. Copy the identifier OUT of the container so your SDK can pin it:
       docker cp <container>:/var/lib/ockam-server/admin/identifier .
  2. Hand the SDK an admin client identity. Two options:
       (a) Pre-bake one identifier into ADMIN_IDENTIFIERS env at boot
       (b) curl POST the controller (via Ockam tunnel) to add admins later

  3. The ONLY port exposed to the network is 14000/tcp (Ockam transport).
============================================================================
EOM
fi

# Seed / refresh state.yaml's controller outlet allow list from env
mkdir -p "$(dirname "${STATE_FILE}")"
chown -R ockam:ockam "$(dirname "${STATE_FILE}")"

ADMINS=${ADMIN_IDENTIFIERS:-${OCKAM_BOOTSTRAP_ADMINS:-}}
runuser -u ockam -- env OCKAM_CONTROLLER_STATE="${STATE_FILE}" OCKAM_BOOTSTRAP_ADMINS="${ADMINS}" \
  /opt/venv/bin/python -m ockam_controller.bootstrap \
  --state "${STATE_FILE}" --admin-identifiers "${ADMINS}" || true

# OCKAM_CONTROLLER_ADMIN_IDENTIFIERS — used by controller's auth.py to
# decide which incoming identifier counts as 'admin'
export OCKAM_CONTROLLER_ADMIN_IDENTIFIERS=${ADMINS}

echo "[entrypoint] handing off to supervisord"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
