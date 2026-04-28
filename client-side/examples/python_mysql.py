"""
Minimal end-to-end example: open an Ockam tunnel, talk to MySQL through it.

Reads connection info from env. Run inside a container that has:
  - ockam binary
  - this SDK installed
  - pymysql installed
"""
from __future__ import annotations
import os
import sys
import time

import pymysql

from ockam_client import ProviderAdmin, ServerConfig, Tunnel, Identity


def env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None:
        sys.exit(f"missing env: {name}")
    return v


def main() -> int:
    cfg = ServerConfig(
        host=env("OCKAM_SERVER_HOST"),
        port=int(env("OCKAM_SERVER_PORT", "14000")),
        expected_identifier=os.environ.get("OCKAM_SERVER_IDENTIFIER") or None,
    )
    ockam_home = env("OCKAM_HOME", "/var/lib/ockam-client")

    target_outlet  = env("OCKAM_OUTLET", "mysql")
    upstream_target = env("OCKAM_UPSTREAM", "mysql:3306")  # only used to ensure_outlet

    db_user = env("MYSQL_USER", "demo")
    db_pwd  = env("MYSQL_PASSWORD", "demopw")
    db_name = env("MYSQL_DATABASE", "demo")

    # 1. Identity + admin: ensure outlet exists
    admin_id = Identity.load_or_create(home=ockam_home, name="admin")
    print(f"[client] admin identifier: {admin_id.identifier}")

    print("[client] opening admin tunnel to ensure outlet...")
    with ProviderAdmin(server=cfg, identity=admin_id) as admin:
        info = admin.info()
        print(f"[client] provider info: {info}")
        admin.ensure_outlet(name=target_outlet,
                            target=upstream_target,
                            allow=[admin_id.identifier])
        outlets = admin.list_outlets()
        print(f"[client] outlets now: {[o['name'] for o in outlets]}")

    # 2. Open data tunnel and run actual SQL
    print("[client] opening data tunnel...")
    with Tunnel.open(server=cfg, target=target_outlet, identity=admin_id) as tun:
        print(f"[client] tunnel: 127.0.0.1:{tun.port} -> {target_outlet}")
        # Tiny retry loop: real-world apps would use a pool
        last = None
        for attempt in range(1, 10):
            try:
                conn = pymysql.connect(
                    host=tun.host, port=tun.port,
                    user=db_user, password=db_pwd, database=db_name,
                    connect_timeout=5,
                )
                break
            except Exception as e:
                last = e
                time.sleep(1)
        else:
            sys.exit(f"could not connect to mysql via tunnel: {last}")

        with conn.cursor() as cur:
            secret = f"PLAINTEXT_SECRET_VIA_OCKAM_AT_{int(time.time())}"
            cur.execute(
                "INSERT INTO messages (sender, content) VALUES (%s, %s)",
                ("python-sdk", secret),
            )
            conn.commit()
            cur.execute("SELECT id, sender, content FROM messages ORDER BY id")
            print("[client] rows in `messages`:")
            for r in cur.fetchall():
                print(f"  id={r[0]} sender={r[1]} content={r[2]}")
        conn.close()
    print("[client] DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
