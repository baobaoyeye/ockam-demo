# ockam-client (Python SDK)

Python SDK that lets your application access a remote TCP service through an authenticated, Noise-XX-encrypted Ockam tunnel.

```python
from ockam_client import connect
import pymysql

with connect(server="provider.example.com:14000",
             target_outlet="mysql",
             ockam_home="/var/lib/ockam-client") as tun:
    conn = pymysql.connect(host=tun.host, port=tun.port,
                           user="app", password="...", database="orders")
    # ...your unchanged SQL code...
```

The `host`/`port` you pass to your driver is `127.0.0.1:<auto-port>` on your local machine. The SDK runs an Ockam node + tcp-inlet under the hood; everything that leaves the host is Noise-XX-encrypted.

- **Deployment guide**: [DEPLOY.md](DEPLOY.md) — how to install, package, embed in container images.
- **API guide**: [SDK.md](SDK.md) — every public class/method, error model, integration recipes.

## Requires

- Python 3.10+
- `ockam` binary in `$PATH` (or set `OCKAM_BINARY=/path/to/ockam`)
- A deployed `ockam-server` ([../../ockam-server](../../ockam-server))
