#!/usr/bin/env bash
# Install OS-level deps: python3, pip, curl, jq, tar, ss/netstat (best effort).
install_deps() {
  case "${OS_FAMILY}" in
    debian)
      apt-get update -qq >/dev/null
      ${PKG_INSTALL} python3 python3-pip python3-venv curl jq tar iproute2 \
        ca-certificates netcat-openbsd >/dev/null
      ln -sf "$(command -v python3)" /usr/local/bin/python-ockam-host
      ;;
    rhel|openeuler)
      # util-linux-user provides `runuser`, which we need to drop privileges.
      # Some images preinstall curl-minimal which conflicts with full curl.
      pkgs="python3 python3-pip jq tar iproute ca-certificates nmap-ncat util-linux-user"
      command -v curl >/dev/null || pkgs="${pkgs} curl"
      # shellcheck disable=SC2086
      ${PKG_INSTALL} ${pkgs} >/dev/null
      # Try to upgrade to 3.11 if the BaseOS module has it; soft-fail otherwise.
      if ! command -v python3.11 >/dev/null && [[ "${OS_FAMILY}" == "rhel" ]]; then
        ${PKG_INSTALL} python3.11 python3.11-pip >/dev/null 2>&1 || true
      fi
      if   command -v python3.11 >/dev/null; then
        ln -sf "$(command -v python3.11)" /usr/local/bin/python-ockam-host
      else
        ln -sf "$(command -v python3)" /usr/local/bin/python-ockam-host
      fi
      ;;
    *)
      echo "[deps] WARN: unknown OS_FAMILY=${OS_FAMILY}; skipping dependency install"
      ;;
  esac

  command -v python3 >/dev/null  || { echo "[deps] python3 required" >&2; exit 1; }
  command -v curl    >/dev/null  || { echo "[deps] curl required" >&2; exit 1; }
}
