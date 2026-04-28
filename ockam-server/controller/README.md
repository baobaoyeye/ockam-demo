# ockam-controller

Tiny FastAPI control-plane that wraps the `ockam` CLI. Lives next to an Ockam node and exposes an HTTP API so our SDK can remotely:

- create / patch / delete TCP outlets
- manage the per-outlet allow-list of client identifiers
- query node identity, outlet status, audit log

The controller is **always** bound to `127.0.0.1` (not exposed to the network). Remote SDK callers reach it indirectly: through a special `controller` outlet on the same Ockam node, which makes the controller subject to the same Noise-XX encryption + identity authorization as data outlets.

For deployment guides see [DEPLOY.md](DEPLOY.md). For the API contract see [SDK.md](SDK.md).

## Quick local smoke test (no ockam binary required)

```bash
pip install -e '.[dev]'
OCKAM_CONTROLLER_MOCK=1 OCKAM_CONTROLLER_TRUST_ALL=1 \
  OCKAM_CONTROLLER_STATE=/tmp/controller-state.yaml \
  python -m ockam_controller --bind 127.0.0.1:8080 &

curl -s http://127.0.0.1:8080/healthz
curl -s -X POST http://127.0.0.1:8080/outlets \
     -H 'Content-Type: application/json' \
     -d '{"name":"mysql","target":"10.0.0.5:3306","allow":[]}'
curl -s http://127.0.0.1:8080/outlets
```

Or just run `./verify.sh`.
