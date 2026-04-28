"""
Authentication for the controller HTTP API.

The controller is meant to live behind an Ockam tcp-outlet that injects the
authenticated peer's identity into the request. Concretely, this controller
trusts the value of the request header named by `IDENTIFIER_HEADER` —
which can ONLY be set by traffic that came through that outlet, because
the controller binds 127.0.0.1 and the outlet is the sole reachable path.

For tests / verify.sh / Mode A bring-up, you can:
  - set OCKAM_CONTROLLER_BOOTSTRAP_TOKEN=...   to allow `Authorization: Bearer <token>`
  - set OCKAM_CONTROLLER_TRUST_ALL=1           to accept any caller as admin
"""
from __future__ import annotations
import os
from fastapi import Header, HTTPException, Request, status

IDENTIFIER_HEADER = "X-Ockam-Remote-Identifier"


class AuthCtx:
    def __init__(self, identifier: str, role: str):
        self.identifier = identifier
        self.role = role        # "admin" | "client"

    def require_admin(self) -> None:
        if self.role != "admin":
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="admin role required")


def get_admin_identifiers() -> set[str]:
    raw = os.environ.get("OCKAM_CONTROLLER_ADMIN_IDENTIFIERS", "")
    return {x.strip() for x in raw.split(",") if x.strip()}


async def auth(request: Request,
               x_ockam_remote_identifier: str | None = Header(default=None),
               authorization: str | None = Header(default=None)) -> AuthCtx:
    # 1) Trust-all mode (only for local tests)
    if os.environ.get("OCKAM_CONTROLLER_TRUST_ALL") == "1":
        return AuthCtx(identifier="trust-all", role="admin")

    # 2) Bootstrap bearer token (only for first contact / dev)
    bootstrap = os.environ.get("OCKAM_CONTROLLER_BOOTSTRAP_TOKEN")
    if bootstrap and authorization == f"Bearer {bootstrap}":
        return AuthCtx(identifier="bootstrap", role="admin")

    # 3) Identifier header injected by the upstream Ockam outlet
    if x_ockam_remote_identifier:
        admins = get_admin_identifiers()
        role = "admin" if x_ockam_remote_identifier in admins else "client"
        return AuthCtx(identifier=x_ockam_remote_identifier, role=role)

    raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="no caller identity")
