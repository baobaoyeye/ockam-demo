# ockam-client (Java SDK)

```java
import com.ockam.client.*;

ServerConfig cfg = ServerConfig.builder()
        .host("provider.example.com").port(14000).build();

Identity admin = Identity.loadOrCreate(Path.of("/var/lib/ockam-client"), "admin");

try (ProviderAdmin adm = new ProviderAdmin(cfg, admin)) {
    adm.ensureOutlet("mysql", "10.0.0.5:3306",
                     List.of(admin.identifier()));
}

try (Tunnel tun = Tunnel.open(cfg, "mysql", admin)) {
    String url = "jdbc:mysql://" + tun.host() + ":" + tun.port() + "/orders";
    try (Connection c = DriverManager.getConnection(url, "app", "...")) {
        // ...
    }
}
```

- **API**: see [SDK.md](SDK.md)
- **Build / package / deploy**: see [DEPLOY.md](DEPLOY.md)

## Requires
- JDK 17+
- `ockam` binary in PATH (or env `OCKAM_BINARY`)
- A deployed [ockam-server](../../ockam-server)

## Build the jar

```bash
./scripts/build-artifacts.sh
# Outputs:
#   target/ockam-client-0.1.0-shaded.jar       ← shaded (Jackson included)
#   ../.build/JdbcDemo.class                   ← demo
#   ../.build/mysql-driver.jar                 ← mysql-connector-j
```

## Quick verify

```bash
./verify.sh   # builds, brings up server+mysql+java-app, checks wire is encrypted
```
