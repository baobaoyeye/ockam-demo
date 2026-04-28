"""
Wrapper around the on-disk OCKAM_HOME vault that holds an Ockam Identity.

We don't manipulate the vault file directly — that's the ockam binary's job.
What we do:
  - Hand `OCKAM_HOME=<path>` to subprocesses so they read/write that vault.
  - On first use, create the named identity if absent.
  - Expose .identifier so the SDK + caller can pin / authorize it.
"""
from __future__ import annotations
import json
import os
import shutil
import subprocess
from pathlib import Path

from .errors import IdentityError


def _run_ockam(home: Path, *args: str, timeout: int = 15) -> subprocess.CompletedProcess:
    binary = os.environ.get("OCKAM_BINARY", "ockam")
    if not shutil.which(binary):
        raise IdentityError(
            f"`{binary}` not in PATH; install ockam or set OCKAM_BINARY."
        )
    env = {**os.environ, "OCKAM_HOME": str(home)}
    try:
        return subprocess.run(
            [binary, *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
    except FileNotFoundError as e:
        raise IdentityError(f"ockam not found: {e}") from e
    except subprocess.TimeoutExpired as e:
        raise IdentityError(f"ockam call timed out after {timeout}s: {' '.join(args)}") from e


class Identity:
    """A handle on a local Ockam identity stored in OCKAM_HOME."""

    def __init__(self, home: Path, name: str, identifier: str):
        self.home = home
        self.name = name
        self.identifier = identifier

    def __repr__(self) -> str:
        return f"Identity(name={self.name!r}, identifier={self.identifier!r}, home={self.home})"

    @classmethod
    def load_or_create(cls, home: str | Path, name: str = "default") -> "Identity":
        """
        Open the OCKAM_HOME at `home`. If the named identity exists, load it;
        otherwise create it. Idempotent.
        """
        home = Path(home).expanduser()
        home.mkdir(parents=True, exist_ok=True)

        # Try to read an existing identity first (no side effects)
        cp = _run_ockam(home, "identity", "show", "--output", "json")
        if cp.returncode == 0 and cp.stdout.strip():
            try:
                data = json.loads(cp.stdout)
                ident = data.get("identifier")
                if ident:
                    return cls(home=home, name=name, identifier=ident)
            except json.JSONDecodeError:
                pass

        # Not present — create
        cp = _run_ockam(home, "identity", "create", name)
        if cp.returncode != 0:
            raise IdentityError(
                f"failed to create identity {name!r}: {cp.stderr or cp.stdout}"
            )
        cp = _run_ockam(home, "identity", "show", "--output", "json")
        if cp.returncode != 0:
            raise IdentityError(f"created but cannot read identity: {cp.stderr}")
        try:
            ident = json.loads(cp.stdout).get("identifier")
        except json.JSONDecodeError as e:
            raise IdentityError(f"identity show returned non-JSON: {cp.stdout!r}") from e
        if not ident:
            raise IdentityError("identity show returned no identifier")
        return cls(home=home, name=name, identifier=ident)

    @classmethod
    def load(cls, home: str | Path, name: str = "default") -> "Identity":
        """Open an EXISTING identity. Raises IdentityError if not present."""
        home = Path(home).expanduser()
        if not home.exists():
            raise IdentityError(f"OCKAM_HOME does not exist: {home}")
        cp = _run_ockam(home, "identity", "show", "--output", "json")
        if cp.returncode != 0:
            raise IdentityError(
                f"no identity in {home}: {cp.stderr or cp.stdout}"
            )
        try:
            ident = json.loads(cp.stdout).get("identifier")
        except json.JSONDecodeError as e:
            raise IdentityError(f"identity show returned non-JSON: {cp.stdout!r}") from e
        if not ident:
            raise IdentityError(f"identity show returned no identifier for {home}")
        return cls(home=home, name=name, identifier=ident)
