"""
YAML-backed persistent state for the controller.

State file shape:

    node:
      name: provider
      identifier: I3a6cf...
      transport: 0.0.0.0:14000
    outlets:
      mysql:
        target: 10.0.0.5:3306
        allow:
          - { identifier: I7c91d..., label: app-prod-1, added_at: 2026-04-25T... }
    clients:                # known but not yet authorized to any outlet
      I8d12e...:
        label: data-pipeline
        added_at: 2026-04-25T...
    audit:
      - { ts: ..., event: ..., detail: {...} }   # ring-buffered, max 200

We protect concurrent access with a `filelock.FileLock` so SDK calls from
multiple workers / threads don't corrupt the file.
"""
from __future__ import annotations
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import yaml
from filelock import FileLock

from .models import ClientRef, OutletSpec, OutletView, AuditEvent

_AUDIT_LIMIT = 200


class State:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.lock_path = self.path.with_suffix(self.path.suffix + ".lock")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self._write({
                "node": {"name": "provider", "identifier": "", "transport": "0.0.0.0:14000"},
                "outlets": {},
                "clients": {},
                "audit": [],
            })

    # -- raw IO ---------------------------------------------------------------
    def _lock(self) -> FileLock:
        return FileLock(str(self.lock_path), timeout=10)

    def _read(self) -> dict[str, Any]:
        with self.path.open() as fh:
            return yaml.safe_load(fh) or {}

    def _write(self, data: dict[str, Any]) -> None:
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        with tmp.open("w") as fh:
            yaml.safe_dump(data, fh, sort_keys=False, allow_unicode=True)
        tmp.replace(self.path)

    # -- node ----------------------------------------------------------------
    def get_node(self) -> dict[str, str]:
        with self._lock():
            return dict(self._read().get("node") or {})

    def set_node(self, *, name: str | None = None,
                 identifier: str | None = None,
                 transport: str | None = None) -> None:
        with self._lock():
            data = self._read()
            node = dict(data.get("node") or {})
            if name is not None: node["name"] = name
            if identifier is not None: node["identifier"] = identifier
            if transport is not None: node["transport"] = transport
            data["node"] = node
            self._write(data)

    # -- outlets -------------------------------------------------------------
    def list_outlets(self) -> list[OutletView]:
        with self._lock():
            data = self._read()
            out = []
            for name, raw in (data.get("outlets") or {}).items():
                allow = [ClientRef(**c) for c in (raw.get("allow") or [])]
                out.append(OutletView(
                    name=name,
                    target=raw["target"],
                    allow=allow,
                    state=raw.get("state", "pending"),
                ))
            return out

    def get_outlet(self, name: str) -> OutletView | None:
        for o in self.list_outlets():
            if o.name == name:
                return o
        return None

    def upsert_outlet(self, spec: OutletSpec) -> OutletView:
        with self._lock():
            data = self._read()
            outlets = dict(data.get("outlets") or {})
            existing = outlets.get(spec.name) or {}
            existing_allow = {c["identifier"]: c for c in (existing.get("allow") or [])}
            for ident in spec.allow:
                if ident not in existing_allow:
                    existing_allow[ident] = ClientRef(identifier=ident).model_dump(mode="json")
            outlets[spec.name] = {
                "target": spec.target,
                "allow": list(existing_allow.values()),
                "state": "pending",
            }
            data["outlets"] = outlets
            self._append_audit_locked(data, "outlet_upserted",
                                      {"name": spec.name, "target": spec.target})
            self._write(data)
        return self.get_outlet(spec.name)  # type: ignore[return-value]

    def patch_outlet(self, name: str, *,
                     target: str | None = None,
                     allow_add: list[str] = (),
                     allow_remove: list[str] = ()) -> OutletView | None:
        with self._lock():
            data = self._read()
            outlets = dict(data.get("outlets") or {})
            if name not in outlets:
                return None
            o = dict(outlets[name])
            if target is not None:
                o["target"] = target
            allow_map = {c["identifier"]: c for c in (o.get("allow") or [])}
            for ident in allow_add:
                if ident not in allow_map:
                    allow_map[ident] = ClientRef(identifier=ident).model_dump(mode="json")
            for ident in allow_remove:
                allow_map.pop(ident, None)
            o["allow"] = list(allow_map.values())
            o["state"] = "pending"
            outlets[name] = o
            data["outlets"] = outlets
            self._append_audit_locked(data, "outlet_patched",
                                      {"name": name,
                                       "target": target,
                                       "added": list(allow_add),
                                       "removed": list(allow_remove)})
            self._write(data)
        return self.get_outlet(name)

    def delete_outlet(self, name: str) -> bool:
        with self._lock():
            data = self._read()
            outlets = dict(data.get("outlets") or {})
            if name not in outlets:
                return False
            outlets.pop(name)
            data["outlets"] = outlets
            self._append_audit_locked(data, "outlet_deleted", {"name": name})
            self._write(data)
        return True

    def set_outlet_state(self, name: str, state: str) -> None:
        with self._lock():
            data = self._read()
            outlets = dict(data.get("outlets") or {})
            if name in outlets:
                outlets[name] = {**outlets[name], "state": state}
                data["outlets"] = outlets
                self._write(data)

    # -- clients (registered but unauthorized) -------------------------------
    def list_clients(self) -> list[ClientRef]:
        with self._lock():
            data = self._read()
            return [
                ClientRef(identifier=ident, **(meta or {}))
                for ident, meta in (data.get("clients") or {}).items()
            ]

    def add_client(self, identifier: str, label: str = "") -> ClientRef:
        with self._lock():
            data = self._read()
            clients = dict(data.get("clients") or {})
            if identifier not in clients:
                clients[identifier] = {
                    "label": label,
                    "added_at": datetime.now(timezone.utc).isoformat(),
                }
                data["clients"] = clients
                self._append_audit_locked(data, "client_registered",
                                          {"identifier": identifier, "label": label})
                self._write(data)
            else:
                clients[identifier]["label"] = label or clients[identifier].get("label", "")
                data["clients"] = clients
                self._write(data)
        return ClientRef(identifier=identifier, label=label)

    def remove_client(self, identifier: str) -> bool:
        """Drop the client AND remove from every outlet's allow list."""
        with self._lock():
            data = self._read()
            clients = dict(data.get("clients") or {})
            existed = identifier in clients
            clients.pop(identifier, None)
            data["clients"] = clients
            outlets = dict(data.get("outlets") or {})
            for name, o in outlets.items():
                kept = [c for c in (o.get("allow") or []) if c["identifier"] != identifier]
                if len(kept) != len(o.get("allow") or []):
                    o["allow"] = kept
                    o["state"] = "pending"
                    outlets[name] = o
                    existed = True
            data["outlets"] = outlets
            if existed:
                self._append_audit_locked(data, "client_revoked", {"identifier": identifier})
                self._write(data)
        return existed

    # -- audit ----------------------------------------------------------------
    def list_audit(self, since_iso: str | None = None) -> list[AuditEvent]:
        with self._lock():
            data = self._read()
            events = data.get("audit") or []
            out = []
            for e in events:
                if since_iso and e.get("ts", "") < since_iso:
                    continue
                out.append(AuditEvent(**e))
            return out

    def _append_audit_locked(self, data: dict, event: str, detail: dict) -> None:
        events = list(data.get("audit") or [])
        events.append({
            "ts": datetime.now(timezone.utc).isoformat(),
            "event": event,
            "detail": detail,
        })
        data["audit"] = events[-_AUDIT_LIMIT:]
