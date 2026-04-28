"""
Subprocess wrapper around the `ockam` CLI for transient operations:
  - node create / delete
  - secure-channel create
  - tcp-inlet create

Higher-level lifecycle (Tunnel, ProviderAdmin) builds on this.
"""
from __future__ import annotations
import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .errors import OckamProcessError


_INLET_RE = re.compile(
    r"(?:bound to|listening on|opened TCP listener|TCP inlet (?:created|listening) (?:at|on))\s+"
    r"(?:tcp[:/]+)?(\d{1,3}(?:\.\d{1,3}){3}|\[?[0-9a-fA-F:]+\]?):(\d+)",
    re.IGNORECASE,
)


@dataclass
class OckamRunner:
    """Run ockam CLI commands with a specific OCKAM_HOME and a node name."""
    home: Path
    binary: str = "ockam"

    def _env(self) -> dict[str, str]:
        env = {**os.environ, "OCKAM_HOME": str(self.home)}
        return env

    def run(self, *args: str, timeout: int = 30, check: bool = True) -> subprocess.CompletedProcess:
        if not shutil.which(self.binary):
            raise OckamProcessError(
                f"`{self.binary}` not found on PATH; install ockam or set OCKAM_BINARY"
            )
        try:
            cp = subprocess.run(
                [self.binary, *args],
                env=self._env(),
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as e:
            raise OckamProcessError(
                f"ockam {' '.join(args)} timed out after {timeout}s",
                stderr=str(e),
            ) from e
        if check and cp.returncode != 0:
            raise OckamProcessError(
                f"ockam {' '.join(args)} failed (exit {cp.returncode})",
                stderr=cp.stderr or cp.stdout,
                returncode=cp.returncode,
            )
        return cp

    # -- node lifecycle -------------------------------------------------------
    def node_create(self, name: str, listen: str = "127.0.0.1:0") -> None:
        # Idempotent: delete first to avoid 'node already exists' on restart.
        self.run("node", "delete", name, "--yes", check=False)
        self.run("node", "create", name, "--tcp-listener-address", listen, timeout=20)

    def node_delete(self, name: str) -> None:
        self.run("node", "delete", name, "--yes", check=False, timeout=15)

    # -- secure channel -------------------------------------------------------
    def secure_channel_create(self, *, from_node: str, server_host: str,
                              server_port: int,
                              authorized: str | None = None,
                              timeout: int = 30) -> str:
        """Create a secure channel; returns the local route address (`/service/...`)."""
        target = f"/dnsaddr/{server_host}/tcp/{server_port}/service/api"
        args = ["secure-channel", "create",
                "--from", f"/node/{from_node}",
                "--to", target]
        if authorized:
            args += ["--authorized", authorized]
        cp = self.run(*args, timeout=timeout)
        # Output format: a few lines of "Creating Secure Channel..." then the
        # route on its own line, e.g. "/service/abcdef0123..."
        lines = [ln.strip() for ln in cp.stdout.splitlines() if ln.strip()]
        for ln in reversed(lines):
            if ln.startswith("/service/") or ln.startswith("/node/"):
                return ln
        raise OckamProcessError(
            "could not parse secure-channel route from ockam output",
            stderr=cp.stdout + "\n---\n" + cp.stderr,
        )

    # -- tcp-inlet ------------------------------------------------------------
    def tcp_inlet_create(self, *, node: str, route_to: str,
                         from_addr: str = "127.0.0.1:0",
                         timeout: int = 20) -> tuple[str, int]:
        """Create a tcp-inlet on `node` and return (host, port) it bound to."""
        cp = self.run(
            "tcp-inlet", "create",
            "--at", node,
            "--from", from_addr,
            "--to", route_to,
            timeout=timeout,
        )
        merged = (cp.stdout or "") + "\n" + (cp.stderr or "")
        m = _INLET_RE.search(merged)
        if m:
            host, port = m.group(1), int(m.group(2))
            return host.strip("[]"), port
        # Some ockam versions print just "127.0.0.1:NNNN" on its own line
        for ln in merged.splitlines():
            ln = ln.strip()
            if ":" in ln:
                host, _, port_s = ln.rpartition(":")
                if port_s.isdigit() and host.replace(".", "").replace("[", "").replace("]", "").replace(":", "").replace("a", "").isdigit() is False:
                    pass
                if port_s.isdigit():
                    return host.strip("[]"), int(port_s)
        raise OckamProcessError(
            "could not parse tcp-inlet bound address from ockam output",
            stderr=merged,
        )
