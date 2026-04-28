#!/usr/bin/env bash
# Verify the install: services up, ports listening, controller responding.

healthcheck() {
  local fail=0
  echo
  echo "===== healthcheck ====="

  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    for u in ockam-server ockam-controller; do
      if systemctl is-active --quiet "${u}"; then
        echo "  [ok]   systemctl ${u}: active"
      else
        echo "  [FAIL] systemctl ${u}: $(systemctl is-active "${u}")"
        fail=1
      fi
    done
  else
    echo "  [skip] systemd not active; cannot check unit status"
  fi

  # Port 14000 listening?
  if command -v ss >/dev/null && ss -tlnp 2>/dev/null | grep -q ":14000\b"; then
    echo "  [ok]   tcp:14000 is listening"
  elif command -v netstat >/dev/null && netstat -tlnp 2>/dev/null | grep -q ":14000\b"; then
    echo "  [ok]   tcp:14000 is listening (netstat)"
  else
    echo "  [warn] cannot confirm tcp:14000 listening (no ss / netstat or not yet bound)"
    fail=1
  fi

  # Controller responding on lo?
  if command -v curl >/dev/null; then
    if curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
      echo "  [ok]   controller /healthz on 127.0.0.1:8080"
    else
      echo "  [FAIL] controller /healthz on 127.0.0.1:8080 not reachable"
      fail=1
    fi
  fi

  # Provider identifier file?
  if [[ -s /var/lib/ockam-server/admin/identifier ]]; then
    echo "  [ok]   provider identifier: $(cat /var/lib/ockam-server/admin/identifier)"
  else
    echo "  [warn] /var/lib/ockam-server/admin/identifier not yet written"
  fi

  echo "======================="
  return ${fail}
}
