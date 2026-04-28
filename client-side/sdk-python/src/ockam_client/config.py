"""Configuration dataclasses with sensible defaults."""
from __future__ import annotations
from dataclasses import dataclass

DEFAULT_SERVER_PORT = 14000
CONTROLLER_OUTLET_NAME = "controller"


@dataclass(frozen=True)
class ServerConfig:
    """How to reach a deployed ockam-server (Mode A docker / Mode B host)."""
    host: str
    port: int = DEFAULT_SERVER_PORT
    # Optional: pin the provider's identifier to defeat MITM. SDK refuses to
    # connect if the secure-channel-time identifier doesn't match.
    expected_identifier: str | None = None
    # secure-channel handshake + node bring-up timeout (seconds)
    connect_timeout: float = 30.0

    @property
    def address(self) -> str:
        return f"{self.host}:{self.port}"
