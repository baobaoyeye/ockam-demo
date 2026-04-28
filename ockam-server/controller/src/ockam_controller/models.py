"""Pydantic schemas for the controller HTTP API."""
from __future__ import annotations
from datetime import datetime, timezone
from typing import Optional
from pydantic import BaseModel, Field, field_validator


class HealthResp(BaseModel):
    status: str                          # "ok" | "degraded" | "down"
    ockam_node: str                      # "running" | "missing"
    outlets_total: int
    outlets_ok: int
    version: str


class InfoResp(BaseModel):
    node_name: str
    identifier: str                      # provider's ockam identity identifier
    transport: str                       # e.g. "0.0.0.0:14000"
    version: str


class ClientRef(BaseModel):
    identifier: str = Field(..., min_length=8)
    label: str = Field(default="")
    added_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class OutletSpec(BaseModel):
    """Create / replace an outlet."""
    name: str = Field(..., pattern=r"^[a-zA-Z0-9_-]{1,64}$")
    target: str = Field(..., min_length=3)        # host:port
    allow: list[str] = Field(default_factory=list)

    @field_validator("target")
    @classmethod
    def target_has_port(cls, v: str) -> str:
        if ":" not in v:
            raise ValueError("target must be 'host:port'")
        host, _, port = v.rpartition(":")
        if not host or not port.isdigit():
            raise ValueError("target must be 'host:port' with numeric port")
        return v


class OutletPatch(BaseModel):
    target: Optional[str] = None
    allow_add: list[str] = Field(default_factory=list)
    allow_remove: list[str] = Field(default_factory=list)


class OutletView(BaseModel):
    name: str
    target: str
    allow: list[ClientRef]
    state: str                           # "ready" | "pending" | "error: <msg>"


class ClientCreate(BaseModel):
    identifier: str = Field(..., min_length=8)
    label: str = Field(default="")


class AuditEvent(BaseModel):
    ts: datetime
    event: str                           # "client_connected" / "outlet_created" / ...
    detail: dict
