"""`python -m ockam_controller --bind 127.0.0.1:8080` entrypoint."""
from __future__ import annotations
import argparse
import os
import sys
import uvicorn


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="ockam-controller")
    p.add_argument("--bind", default="127.0.0.1:8080",
                   help="host:port to bind (default 127.0.0.1:8080)")
    p.add_argument("--state",
                   default=os.environ.get("OCKAM_CONTROLLER_STATE",
                                          "/var/lib/ockam-controller/state.yaml"),
                   help="path to state.yaml")
    p.add_argument("--log-level", default="info")
    args = p.parse_args(argv)

    os.environ["OCKAM_CONTROLLER_STATE"] = args.state

    host, _, port = args.bind.rpartition(":")
    if not port.isdigit():
        print(f"invalid --bind: {args.bind}", file=sys.stderr)
        return 2

    uvicorn.run(
        "ockam_controller.app:app",
        host=host or "127.0.0.1",
        port=int(port),
        log_level=args.log_level,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
