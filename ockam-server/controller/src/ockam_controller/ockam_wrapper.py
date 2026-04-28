"""
Wraps the `ockam` CLI so the rest of the controller can call ensure_outlet()
etc. without caring about subprocess plumbing.

Has two implementations:
  - RealOckam   — invokes the actual ockam binary on the host
  - MockOckam   — records calls in memory; used by tests / verify.sh when no
                  ockam binary is available

Pick one with `ockam_wrapper.from_env()` based on `OCKAM_CONTROLLER_MOCK=1`.

Note: outlet `--allow` accepts an Ockam policy expression. We render it from
a list of identifiers as `(or (= subject.identifier "I...") (= ...))`. An
empty list ⇒ `false` (deny everything) — safer than `any`.
"""
from __future__ import annotations
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Protocol


class OckamError(RuntimeError):
    pass


def render_allow(identifiers: list[str]) -> str:
    if not identifiers:
        return "false"
    if len(identifiers) == 1:
        return f'(= subject.identifier "{identifiers[0]}")'
    parts = " ".join(f'(= subject.identifier "{i}")' for i in identifiers)
    return f"(or {parts})"


class Ockam(Protocol):
    """Subset of `ockam` CLI used by the controller."""
    def node_show(self, name: str) -> dict: ...
    def node_create(self, name: str, listen: str) -> None: ...
    def identity_show(self, name: str) -> str: ...
    def outlet_create(self, *, node: str, name: str, target: str, allow_expr: str) -> None: ...
    def outlet_delete(self, *, node: str, name: str) -> None: ...
    def outlet_list(self, *, node: str) -> list[dict]: ...


@dataclass
class RealOckam:
    binary: str = "ockam"

    def _run(self, *args: str, check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
        cmd = [self.binary, *args]
        try:
            return subprocess.run(
                cmd,
                check=check,
                capture_output=capture,
                text=True,
                timeout=30,
            )
        except FileNotFoundError as e:
            raise OckamError(f"ockam binary not found at '{self.binary}'") from e
        except subprocess.CalledProcessError as e:
            raise OckamError(f"`{' '.join(cmd)}` failed: {e.stderr or e.stdout}") from e

    def node_show(self, name: str) -> dict:
        cp = self._run("node", "show", name, "--output", "json", check=False)
        if cp.returncode != 0:
            return {}
        try:
            import json
            return json.loads(cp.stdout)
        except Exception:
            return {}

    def node_create(self, name: str, listen: str) -> None:
        # Idempotent: skip if already exists
        if self.node_show(name):
            return
        self._run("node", "create", name, "--tcp-listener-address", listen)

    def identity_show(self, name: str) -> str:
        # Get default identity identifier
        cp = self._run("identity", "show", "--output", "json")
        try:
            import json
            return json.loads(cp.stdout).get("identifier", "")
        except Exception:
            return cp.stdout.strip()

    def outlet_create(self, *, node: str, name: str, target: str, allow_expr: str) -> None:
        # ockam tcp-outlet create is idempotent on `name` only if --from is set.
        # Easiest path: try to delete first, ignore failures.
        self._run("tcp-outlet", "delete", "--at", node, name, check=False)
        self._run(
            "tcp-outlet", "create",
            "--at", node,
            "--to", target,
            "--from", f"/service/{name}",
            "--allow", allow_expr,
        )

    def outlet_delete(self, *, node: str, name: str) -> None:
        self._run("tcp-outlet", "delete", "--at", node, name, check=False)

    def outlet_list(self, *, node: str) -> list[dict]:
        cp = self._run("tcp-outlet", "list", "--at", node, "--output", "json", check=False)
        if cp.returncode != 0 or not cp.stdout.strip():
            return []
        try:
            import json
            return json.loads(cp.stdout)
        except Exception:
            return []


@dataclass
class MockOckam:
    """In-memory record of calls. Used by tests and B1's verify.sh."""
    calls: list[tuple[str, dict]] = field(default_factory=list)
    nodes: dict[str, dict] = field(default_factory=dict)
    outlets: dict[tuple[str, str], dict] = field(default_factory=dict)
    identifier: str = "Imock0000mock0000mock0000mock0000mock0000mock0000mock0000mock00ab"

    def node_show(self, name: str) -> dict:
        self.calls.append(("node_show", {"name": name}))
        return self.nodes.get(name, {})

    def node_create(self, name: str, listen: str) -> None:
        self.calls.append(("node_create", {"name": name, "listen": listen}))
        self.nodes[name] = {"name": name, "transport": listen, "status": "running"}

    def identity_show(self, name: str = "default") -> str:
        self.calls.append(("identity_show", {"name": name}))
        return self.identifier

    def outlet_create(self, *, node: str, name: str, target: str, allow_expr: str) -> None:
        self.calls.append(("outlet_create",
                           {"node": node, "name": name, "target": target, "allow_expr": allow_expr}))
        self.outlets[(node, name)] = {"target": target, "allow_expr": allow_expr}

    def outlet_delete(self, *, node: str, name: str) -> None:
        self.calls.append(("outlet_delete", {"node": node, "name": name}))
        self.outlets.pop((node, name), None)

    def outlet_list(self, *, node: str) -> list[dict]:
        self.calls.append(("outlet_list", {"node": node}))
        return [{"name": n, **info} for (nd, n), info in self.outlets.items() if nd == node]


def from_env() -> Ockam:
    """Pick implementation based on env vars."""
    if os.environ.get("OCKAM_CONTROLLER_MOCK") == "1":
        return MockOckam()
    binary = os.environ.get("OCKAM_BINARY", "ockam")
    if not shutil.which(binary):
        # Fall back to mock with a warning rather than crashing the controller
        # at startup; the operator can fix the binary path later.
        return MockOckam()
    return RealOckam(binary=binary)
