"""
First-run bootstrap helper.

Used by Mode A entrypoint and Mode B install.sh to:
  - generate an admin identity if none exists
  - seed state.yaml with the controller outlet definition
  - print the admin material location

`reconcile()` in app.py then creates the actual outlet on first uvicorn start.
"""
from __future__ import annotations
import argparse
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

from .models import OutletSpec
from .state import State

# The controller outlet is the SDK's only path to the management API.
# It must accept the admin identifiers; defaults to "deny all" until at
# least one admin is registered.
CONTROLLER_OUTLET_NAME = "controller"
CONTROLLER_LOCAL_TARGET = "127.0.0.1:8080"


def gen_admin_token() -> str:
    return secrets.token_urlsafe(32)


def ockam_default_identifier(binary: str = "ockam") -> str:
    """Best-effort: read the default identity's identifier; create one if missing."""
    if not shutil.which(binary):
        return ""
    try:
        cp = subprocess.run([binary, "identity", "show", "--output", "json"],
                            capture_output=True, text=True, timeout=10)
        if cp.returncode == 0:
            import json
            return json.loads(cp.stdout).get("identifier", "")
        # Identity doesn't exist yet; create a default one
        subprocess.run([binary, "identity", "create", "default"], check=True, timeout=15)
        cp = subprocess.run([binary, "identity", "show", "--output", "json"],
                            capture_output=True, text=True, timeout=10)
        if cp.returncode == 0:
            import json
            return json.loads(cp.stdout).get("identifier", "")
    except Exception:
        pass
    return ""


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="ockam-controller-bootstrap")
    p.add_argument("--state",
                   default=os.environ.get("OCKAM_CONTROLLER_STATE",
                                          "/var/lib/ockam-controller/state.yaml"))
    p.add_argument("--admin-identifiers", default=os.environ.get("OCKAM_BOOTSTRAP_ADMINS", ""),
                   help="comma-separated admin identifier(s) to seed (optional)")
    args = p.parse_args(argv)

    state = State(args.state)

    admins = [x.strip() for x in args.admin_identifiers.split(",") if x.strip()]
    spec = OutletSpec(
        name=CONTROLLER_OUTLET_NAME,
        target=CONTROLLER_LOCAL_TARGET,
        allow=admins,
    )
    state.upsert_outlet(spec)
    for ident in admins:
        state.add_client(ident, label="admin")

    print(f"[bootstrap] state file:    {args.state}")
    print(f"[bootstrap] controller outlet seeded ({CONTROLLER_OUTLET_NAME} -> {CONTROLLER_LOCAL_TARGET})")
    if admins:
        print(f"[bootstrap] admin identifiers ({len(admins)}): {', '.join(admins)}")
    else:
        print("[bootstrap] WARNING: no admin identifiers seeded — controller outlet will deny ALL")
        print("[bootstrap] use `curl -X POST .../outlets/controller -d {...allow_add: [I...]}'`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
