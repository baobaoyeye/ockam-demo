"""
connect() — convenience all-in-one for the 90% case.

Combines:
  1. Load / create the local app identity
  2. Open a Tunnel to the data-plane outlet
  3. (optionally) ensure the outlet exists on the server first

Returns a Tunnel — use it as a context manager.

Example:
    from ockam_client import connect

    with connect(
        server="provider.example.com:14000",
        target_outlet="mysql",
        target="10.0.0.5:3306",       # optional: ensure this is the outlet target
        ockam_home="/var/lib/ockam-client",
        admin_identity_name="admin",  # optional, only if you also want to ensure_outlet
    ) as tun:
        conn = pymysql.connect(host=tun.host, port=tun.port, ...)
"""
from __future__ import annotations
from typing import Optional

from .admin import ProviderAdmin
from .config import ServerConfig
from .errors import OckamClientError
from .identity import Identity
from .tunnel import Tunnel


def connect(*,
            server: ServerConfig | str,
            target_outlet: str,
            target: Optional[str] = None,
            ockam_home: str = "/var/lib/ockam-client",
            app_identity_name: str = "app",
            admin_identity_name: Optional[str] = None,
            expected_identifier: Optional[str] = None) -> Tunnel:
    """
    One-shot helper. If `target` is provided AND `admin_identity_name` is
    provided, ensures the outlet exists/maps to that target before opening
    the tunnel — useful for self-bootstrapping deployments.

    Otherwise: just opens a tunnel to the (assumed pre-configured) outlet.
    """
    cfg = server if isinstance(server, ServerConfig) else _parse(server, expected_identifier)

    # App identity (used for the data tunnel handshake + outlet allow check)
    app_id = Identity.load_or_create(home=ockam_home, name=app_identity_name)

    # Optionally bootstrap: ensure the outlet exists / matches `target`
    if target and admin_identity_name:
        admin_id = Identity.load_or_create(home=ockam_home, name=admin_identity_name)
        with ProviderAdmin(server=cfg, identity=admin_id) as admin:
            admin.ensure_outlet(name=target_outlet, target=target,
                                allow=[app_id.identifier])

    return Tunnel.open(server=cfg, target=target_outlet, identity=app_id)


def _parse(s: str, expected_identifier: Optional[str]) -> ServerConfig:
    if ":" not in s:
        raise OckamClientError(f"server must be 'host:port', got {s!r}")
    host, _, port_s = s.rpartition(":")
    if not port_s.isdigit():
        raise OckamClientError(f"server port must be int, got {port_s!r}")
    return ServerConfig(host=host, port=int(port_s),
                        expected_identifier=expected_identifier)
