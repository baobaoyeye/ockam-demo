#!/usr/bin/env bash
# Detect OS family / package manager / arch. Sets:
#   OS_FAMILY   : "rhel" | "debian" | "openeuler" | "unknown"
#   OS_NAME     : pretty name from /etc/os-release
#   PKG_MANAGER : "dnf" | "yum" | "apt-get" | "unknown"
#   PKG_INSTALL : full install verb to use
#   ARCH        : "x86_64" | "aarch64" | ...
detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    OS_FAMILY=unknown OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
    PKG_MANAGER=unknown PKG_INSTALL=":"
    ARCH="$(uname -m)"
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-${NAME:-${ID}}}"
  ARCH="$(uname -m)"

  case "${ID:-},${ID_LIKE:-}" in
    *openEuler*|*openeuler*)
      OS_FAMILY=openeuler
      PKG_MANAGER=$(command -v dnf >/dev/null && echo dnf || echo yum)
      ;;
    *rhel*|*centos*|*rocky*|*almalinux*|*fedora*|*ol*)
      OS_FAMILY=rhel
      PKG_MANAGER=$(command -v dnf >/dev/null && echo dnf || echo yum)
      ;;
    *ubuntu*|*debian*)
      OS_FAMILY=debian
      PKG_MANAGER=apt-get
      ;;
    *)
      OS_FAMILY=unknown
      PKG_MANAGER=$(command -v dnf >/dev/null && echo dnf \
                  || command -v yum >/dev/null && echo yum \
                  || command -v apt-get >/dev/null && echo apt-get \
                  || echo unknown)
      ;;
  esac

  case "${PKG_MANAGER}" in
    apt-get) PKG_INSTALL="${PKG_MANAGER} install -y --no-install-recommends" ;;
    dnf|yum) PKG_INSTALL="${PKG_MANAGER} install -y" ;;
    *)       PKG_INSTALL=":" ;;
  esac
}
