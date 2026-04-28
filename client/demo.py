"""
Python -> MySQL demo client.

Reads connection params from env, connects WITHOUT TLS, performs an insert
and a select, and prints the results. Used in both Phase 1 (direct to MySQL)
and Phase 2 (through Ockam local inlet) — only the host/port differ.
"""
import os
import sys
import time
import pymysql


def env(name: str, default: str = "") -> str:
    v = os.environ.get(name, default)
    if not v:
        print(f"[client] missing env: {name}", file=sys.stderr)
        sys.exit(2)
    return v


def main() -> int:
    host = env("MYSQL_HOST")
    port = int(env("MYSQL_PORT"))
    user = env("MYSQL_USER")
    password = env("MYSQL_PASSWORD")
    database = env("MYSQL_DATABASE")
    label = os.environ.get("DEMO_LABEL", "demo")

    print(f"[client] connecting to {host}:{port} as {user} (db={database}) — UNENCRYPTED transport", flush=True)

    last_err: Exception | None = None
    for attempt in range(1, 31):
        try:
            conn = pymysql.connect(
                host=host,
                port=port,
                user=user,
                password=password,
                database=database,
                connect_timeout=5,
                ssl=None,
            )
            break
        except Exception as e:
            last_err = e
            print(f"[client] attempt {attempt} failed: {e}", flush=True)
            time.sleep(2)
    else:
        print(f"[client] giving up: {last_err}", file=sys.stderr)
        return 1

    try:
        with conn.cursor() as cur:
            secret = f"PLAINTEXT_SECRET_FROM_{label}_AT_{int(time.time())}"
            cur.execute(
                "INSERT INTO messages (sender, content) VALUES (%s, %s)",
                ("client", secret),
            )
            conn.commit()
            print(f"[client] inserted: sender=client content={secret}", flush=True)

            cur.execute("SELECT id, sender, content FROM messages ORDER BY id")
            rows = cur.fetchall()
            print("[client] rows currently in `messages`:", flush=True)
            for r in rows:
                print(f"  id={r[0]} sender={r[1]} content={r[2]}", flush=True)
    finally:
        conn.close()

    print("[client] done", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
