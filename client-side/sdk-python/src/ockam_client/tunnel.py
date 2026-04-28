"""
Tunnel — encrypted point-to-point access to a remote tcp-outlet.

Usage:
    with Tunnel.open(server=cfg, target="mysql", identity=app_id) as tun:
        host, port = tun.host, tun.port
        # use host:port with your driver

Lifecycle:
    1. Create a unique short-lived ockam node (named `tunnel-<pid>-<random>`)
       inside `identity.home`.
    2. Open a Noise XX secure channel to server's /service/api.
       If `cfg.expected_identifier` is set, pass --authorized to defeat MITM.
    3. Create a tcp-inlet bound to 127.0.0.1:0 (random free port) routed
       through the secure channel to /service/<target>.
    4. Parse the bound address from ockam's output, expose .host / .port.
    5. On close: tcp-inlet/secure-channel are torn down by deleting the node.
"""
from __future__ import annotations
import os
import secrets

from .config import ServerConfig
from .errors import OckamClientError
from .identity import Identity
from .process import OckamRunner


class Tunnel:
    def __init__(self, *, runner: OckamRunner, node: str, host: str, port: int):
        self._runner = runner
        self._node = node
        self.host = host
        self.port = port
        self._closed = False

    def __repr__(self) -> str:
        return f"Tunnel(host={self.host!r}, port={self.port}, node={self._node!r})"

    @property
    def address(self) -> str:
        return f"{self.host}:{self.port}"

    def __enter__(self) -> "Tunnel":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._runner.node_delete(self._node)
        except Exception:
            # Best-effort; leftover node will be replaced next open.
            pass

    @classmethod
    def open(cls, *,
             server: ServerConfig | str,
             target: str,
             identity: Identity,
             node_name: str | None = None) -> "Tunnel":
        cfg = server if isinstance(server, ServerConfig) else _parse_server_arg(server)
        runner = OckamRunner(home=identity.home,
                             binary=os.environ.get("OCKAM_BINARY", "ockam"))
        node = node_name or f"tun-{os.getpid()}-{secrets.token_hex(3)}"

        runner.node_create(node, listen="127.0.0.1:0")
        try:
            sc = runner.secure_channel_create(
                from_node=node,
                server_host=cfg.host,
                server_port=cfg.port,
                authorized=cfg.expected_identifier,
                timeout=int(cfg.connect_timeout),
            )
            host, port = runner.tcp_inlet_create(
                node=node,
                route_to=f"{sc}/service/{target}",
                from_addr="127.0.0.1:0",
            )
        except Exception:
            runner.node_delete(node)
            raise
        return cls(runner=runner, node=node, host=host, port=port)


def _parse_server_arg(s: str) -> ServerConfig:
    if ":" not in s:
        raise OckamClientError(f"server must be 'host:port', got {s!r}")
    host, _, port_s = s.rpartition(":")
    if not port_s.isdigit():
        raise OckamClientError(f"server port must be int, got {port_s!r}")
    return ServerConfig(host=host, port=int(port_s))
