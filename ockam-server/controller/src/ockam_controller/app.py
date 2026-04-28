"""FastAPI app — control-plane API for an Ockam server node."""
from __future__ import annotations
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, Depends, HTTPException, Request, status

from . import __version__
from .auth import AuthCtx, auth
from .models import (
    AuditEvent, ClientCreate, ClientRef, HealthResp, InfoResp,
    OutletPatch, OutletSpec, OutletView,
)
from .ockam_wrapper import Ockam, from_env as ockam_from_env, render_allow
from .state import State

STATE_PATH = os.environ.get("OCKAM_CONTROLLER_STATE",
                            "/var/lib/ockam-controller/state.yaml")
NODE_NAME = os.environ.get("OCKAM_NODE_NAME", "provider")
TRANSPORT = os.environ.get("OCKAM_NODE_TRANSPORT", "0.0.0.0:14000")


def reconcile(ockam: Ockam, state: State) -> dict[str, str]:
    """Bring the live ockam node in line with persisted state. Idempotent."""
    try:
        ockam.node_create(NODE_NAME, TRANSPORT)
    except Exception as e:
        return {"node": f"error: {e}"}

    try:
        state.set_node(name=NODE_NAME,
                       identifier=ockam.identity_show("default"),
                       transport=TRANSPORT)
    except Exception:
        pass

    statuses: dict[str, str] = {}
    for o in state.list_outlets():
        try:
            ockam.outlet_create(
                node=NODE_NAME, name=o.name, target=o.target,
                allow_expr=render_allow([c.identifier for c in o.allow]),
            )
            state.set_outlet_state(o.name, "ready")
            statuses[o.name] = "ready"
        except Exception as e:
            state.set_outlet_state(o.name, f"error: {e}")
            statuses[o.name] = f"error: {e}"
    return statuses


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.state = State(STATE_PATH)
    app.state.ockam = ockam_from_env()
    app.state.last_reconcile = reconcile(app.state.ockam, app.state.state)
    yield


app = FastAPI(title="ockam-controller", version=__version__, lifespan=lifespan)


def get_state(request: Request) -> State:
    return request.app.state.state


def get_ockam(request: Request) -> Ockam:
    return request.app.state.ockam


def _reapply_outlet(state: State, ockam: Ockam, view: OutletView) -> None:
    """Push one outlet's allow-list/target down to the live ockam node."""
    try:
        ockam.outlet_create(
            node=NODE_NAME, name=view.name, target=view.target,
            allow_expr=render_allow([c.identifier for c in view.allow]),
        )
        state.set_outlet_state(view.name, "ready")
    except Exception as e:
        state.set_outlet_state(view.name, f"error: {e}")
        raise HTTPException(500, detail=f"outlet apply failed: {e}")


# ---------- health / info -----------------------------------------------

@app.get("/healthz", response_model=HealthResp)
async def healthz(state: State = Depends(get_state)) -> HealthResp:
    outlets = state.list_outlets()
    ok = sum(1 for o in outlets if o.state == "ready")
    node = state.get_node()
    return HealthResp(
        status="ok" if outlets and ok == len(outlets) else ("degraded" if outlets else "ok"),
        ockam_node="running" if node.get("identifier") else "missing",
        outlets_total=len(outlets),
        outlets_ok=ok,
        version=__version__,
    )


@app.get("/info", response_model=InfoResp)
async def info(state: State = Depends(get_state)) -> InfoResp:
    node = state.get_node()
    return InfoResp(
        node_name=node.get("name", NODE_NAME),
        identifier=node.get("identifier", ""),
        transport=node.get("transport", TRANSPORT),
        version=__version__,
    )


# ---------- outlets -----------------------------------------------------

@app.get("/outlets", response_model=list[OutletView])
async def list_outlets(state: State = Depends(get_state),
                       _ctx: AuthCtx = Depends(auth)) -> list[OutletView]:
    return state.list_outlets()


@app.post("/outlets", response_model=OutletView, status_code=status.HTTP_201_CREATED)
async def upsert_outlet(spec: OutletSpec,
                        state: State = Depends(get_state),
                        ockam: Ockam = Depends(get_ockam),
                        ctx: AuthCtx = Depends(auth)) -> OutletView:
    ctx.require_admin()
    view = state.upsert_outlet(spec)
    _reapply_outlet(state, ockam, view)
    return state.get_outlet(spec.name)  # type: ignore[return-value]


@app.get("/outlets/{name}", response_model=OutletView)
async def get_outlet(name: str,
                     state: State = Depends(get_state),
                     _ctx: AuthCtx = Depends(auth)) -> OutletView:
    o = state.get_outlet(name)
    if not o:
        raise HTTPException(404, "outlet not found")
    return o


@app.patch("/outlets/{name}", response_model=OutletView)
async def patch_outlet(name: str, patch: OutletPatch,
                       state: State = Depends(get_state),
                       ockam: Ockam = Depends(get_ockam),
                       ctx: AuthCtx = Depends(auth)) -> OutletView:
    ctx.require_admin()
    view = state.patch_outlet(
        name,
        target=patch.target,
        allow_add=patch.allow_add,
        allow_remove=patch.allow_remove,
    )
    if not view:
        raise HTTPException(404, "outlet not found")
    _reapply_outlet(state, ockam, view)
    return state.get_outlet(view.name)  # type: ignore[return-value]


@app.delete("/outlets/{name}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_outlet(name: str,
                        state: State = Depends(get_state),
                        ockam: Ockam = Depends(get_ockam),
                        ctx: AuthCtx = Depends(auth)) -> None:
    ctx.require_admin()
    if not state.delete_outlet(name):
        raise HTTPException(404, "outlet not found")
    try:
        ockam.outlet_delete(node=NODE_NAME, name=name)
    except Exception:
        pass


# ---------- clients -----------------------------------------------------

@app.get("/clients", response_model=list[ClientRef])
async def list_clients(state: State = Depends(get_state),
                       _ctx: AuthCtx = Depends(auth)) -> list[ClientRef]:
    return state.list_clients()


@app.post("/clients", response_model=ClientRef, status_code=status.HTTP_201_CREATED)
async def add_client(body: ClientCreate,
                     state: State = Depends(get_state),
                     ctx: AuthCtx = Depends(auth)) -> ClientRef:
    ctx.require_admin()
    return state.add_client(body.identifier, body.label)


@app.delete("/clients/{identifier}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_client(identifier: str,
                        state: State = Depends(get_state),
                        ockam: Ockam = Depends(get_ockam),
                        ctx: AuthCtx = Depends(auth)) -> None:
    ctx.require_admin()
    if not state.remove_client(identifier):
        raise HTTPException(404, "client not found")
    # Membership changed; re-apply every outlet's allow list
    for o in state.list_outlets():
        try:
            ockam.outlet_create(
                node=NODE_NAME, name=o.name, target=o.target,
                allow_expr=render_allow([c.identifier for c in o.allow]),
            )
            state.set_outlet_state(o.name, "ready")
        except Exception as e:
            state.set_outlet_state(o.name, f"error: {e}")


# ---------- audit -------------------------------------------------------

@app.get("/audit", response_model=list[AuditEvent])
async def get_audit(since: str | None = None,
                    state: State = Depends(get_state),
                    _ctx: AuthCtx = Depends(auth)) -> list[AuditEvent]:
    return state.list_audit(since)
