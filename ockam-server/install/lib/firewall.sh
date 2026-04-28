#!/usr/bin/env bash
# Try to open 14000/tcp on the host. Best effort — failures are warnings.

open_port_14000() {
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo "[firewall] firewalld detected; opening 14000/tcp"
    firewall-cmd --add-port=14000/tcp --permanent || true
    firewall-cmd --reload || true
    return 0
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
    echo "[firewall] ufw detected; opening 14000/tcp"
    ufw allow 14000/tcp || true
    return 0
  fi
  if command -v iptables >/dev/null 2>&1; then
    if iptables -L -n 2>/dev/null | head -1 | grep -q Chain; then
      echo "[firewall] iptables detected; appending ACCEPT rule (not persisted)"
      iptables -I INPUT -p tcp --dport 14000 -j ACCEPT 2>/dev/null || true
      return 0
    fi
  fi
  echo "[firewall] no recognised firewall manager active; assuming port is open"
}
