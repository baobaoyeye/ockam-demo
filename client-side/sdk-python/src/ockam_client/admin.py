"""
ProviderAdmin — talk to the remote ockam-server's controller HTTP API
through an Ockam tunnel.

Idiomatic use:
    with ProviderAdmin(server="provider:14000", identity=admin_id) as admin:
        admin.ensure_outlet(name="mysql", target="10.0.0.5:3306")
        admin.ensure_client_authorized(outlet="mysql", identifier="I7c91d...")

`__enter__` opens a Tunnel.open(target="controller"). All admin methods
issue HTTP calls against `http://<inlet host>:<inlet port>/...`.
"""
from __future__ import annotations
from typing import Any
import httpx

from .config import CONTROLLER_OUTLET_NAME, ServerConfig
from .errors import OckamControllerError
from .identity import Identity
from .tunnel import Tunnel


class ProviderAdmin:
    def __init__(self, *, server: ServerConfig | str, identity: Identity,
                 timeout: float = 10.0):
        self._server = server
        self._identity = identity
        self._timeout = timeout
        self._tunnel: Tunnel | None = None
        self._client: httpx.Client | None = None

    def __enter__(self) -> "ProviderAdmin":
        self._tunnel = Tunnel.open(
            server=self._server,
            target=CONTROLLER_OUTLET_NAME,
            identity=self._identity,
        )
        base = f"http://{self._tunnel.host}:{self._tunnel.port}"
        # Send our identifier as a hint; controller will trust it for finer
        # role distinction once that's wired up. Today the controller is in
        # TRUST_ALL mode (the outlet `--allow` is the security boundary).
        headers = {"X-Ockam-Remote-Identifier": self._identity.identifier}
        self._client = httpx.Client(base_url=base, timeout=self._timeout, headers=headers)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def close(self) -> None:
        if self._client:
            try: self._client.close()
            except Exception: pass
            self._client = None
        if self._tunnel:
            self._tunnel.close()
            self._tunnel = None

    # -- helpers --------------------------------------------------------------
    def _http(self) -> httpx.Client:
        if not self._client:
            raise RuntimeError("ProviderAdmin used outside `with`")
        return self._client

    def _check(self, resp: httpx.Response, action: str) -> dict | list | None:
        if 200 <= resp.status_code < 300:
            if resp.status_code == 204 or not resp.content:
                return None
            return resp.json()
        raise OckamControllerError(
            f"{action} failed: HTTP {resp.status_code}",
            status_code=resp.status_code,
            body=resp.text,
        )

    # -- read endpoints -------------------------------------------------------
    def healthz(self) -> dict:
        return self._check(self._http().get("/healthz"), "GET /healthz")  # type: ignore[return-value]

    def info(self) -> dict:
        return self._check(self._http().get("/info"), "GET /info")  # type: ignore[return-value]

    def list_outlets(self) -> list[dict]:
        return self._check(self._http().get("/outlets"), "GET /outlets")  # type: ignore[return-value]

    def list_clients(self) -> list[dict]:
        return self._check(self._http().get("/clients"), "GET /clients")  # type: ignore[return-value]

    def get_audit(self, since: str | None = None) -> list[dict]:
        params = {"since": since} if since else {}
        return self._check(self._http().get("/audit", params=params), "GET /audit")  # type: ignore[return-value]

    # -- write endpoints ------------------------------------------------------
    def ensure_outlet(self, *, name: str, target: str,
                      allow: list[str] | None = None) -> dict:
        """Idempotent upsert. `target` is 'host:port' on the server side."""
        body: dict[str, Any] = {"name": name, "target": target}
        if allow is not None:
            body["allow"] = list(allow)
        else:
            body["allow"] = []
        return self._check(
            self._http().post("/outlets", json=body), f"POST /outlets {name}"
        )  # type: ignore[return-value]

    def ensure_client_authorized(self, *, outlet: str, identifier: str) -> dict:
        return self._check(
            self._http().patch(f"/outlets/{outlet}", json={"allow_add": [identifier]}),
            f"PATCH /outlets/{outlet}",
        )  # type: ignore[return-value]

    def revoke_client_from_outlet(self, *, outlet: str, identifier: str) -> dict:
        return self._check(
            self._http().patch(f"/outlets/{outlet}", json={"allow_remove": [identifier]}),
            f"PATCH /outlets/{outlet}",
        )  # type: ignore[return-value]

    def delete_outlet(self, name: str) -> None:
        self._check(self._http().delete(f"/outlets/{name}"), f"DELETE /outlets/{name}")

    def register_client(self, *, identifier: str, label: str = "") -> dict:
        return self._check(
            self._http().post("/clients", json={"identifier": identifier, "label": label}),
            "POST /clients",
        )  # type: ignore[return-value]

    def revoke_client(self, identifier: str) -> None:
        self._check(self._http().delete(f"/clients/{identifier}"),
                    f"DELETE /clients/{identifier}")
