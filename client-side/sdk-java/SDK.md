# SDK.md — `com.ockam.client` Java API

## 30 秒上手

```java
import com.ockam.client.*;
import java.nio.file.Path;
import java.sql.*;
import java.util.List;

ServerConfig cfg = ServerConfig.parse("provider.example.com:14000");
Identity admin = Identity.loadOrCreate(Path.of("/var/lib/ockam-client"), "admin");

// (一次性) 配置 outlet
try (ProviderAdmin a = new ProviderAdmin(cfg, admin)) {
    a.ensureOutlet("mysql", "10.0.0.5:3306", List.of(admin.identifier()));
}

// (业务循环) 数据通道
try (Tunnel tun = Tunnel.open(cfg, "mysql", admin)) {
    String url = "jdbc:mysql://" + tun.host() + ":" + tun.port() + "/orders"
               + "?useSSL=false&allowPublicKeyRetrieval=true";
    try (Connection conn = DriverManager.getConnection(url, "app", "...")) {
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery("SELECT * FROM orders LIMIT 10")) {
            while (rs.next()) System.out.println(rs.getInt(1));
        }
    }
}
```

## 公共类

### `ServerConfig`

不可变。用 builder 或 parse 静态方法。

```java
ServerConfig cfg = ServerConfig.builder()
    .host("provider.example.com")
    .port(14000)                            // 默认 14000，可省略
    .expectedIdentifier("I3a6cf...")        // 可选，pin provider identity 抗 MITM
    .connectTimeout(Duration.ofSeconds(30)) // 默认 30s
    .build();

// 或
ServerConfig cfg = ServerConfig.parse("host:port");
```

### `Identity`

```java
public static Identity loadOrCreate(Path home, String name);   // 没有就创建
public static Identity load        (Path home, String name);   // 必须存在

public Path   home();
public String name();
public String identifier();   // 一长串 "I_xxx..."
```

不直接持有密钥。所有 vault 操作走 `ockam` CLI（OCKAM_HOME=home）。

### `Tunnel implements AutoCloseable`

```java
public static Tunnel open(ServerConfig cfg, String targetOutlet, Identity identity);
public static Tunnel open(ServerConfig cfg, String targetOutlet, Identity identity, String nodeName);

public String host();    // 一般 "127.0.0.1"
public int    port();    // OS 分配的随机空闲端口
public String address(); // host + ":" + port
public void   close();
```

打开时启动一个本地短寿命 ockam node + 创建 secure-channel + 创建 tcp-inlet。`close()` 删除 node 释放端口。`close()` 永远不抛异常（包含吞掉 timeout）。

### `ProviderAdmin implements AutoCloseable`

```java
ProviderAdmin(ServerConfig cfg, Identity identity);
ProviderAdmin(ServerConfig cfg, Identity identity, Duration httpTimeout);

// 读
JsonNode healthz();
JsonNode info();
JsonNode listOutlets();
JsonNode listClients();

// 写（幂等）
JsonNode ensureOutlet(String name, String target);
JsonNode ensureOutlet(String name, String target, List<String> allow);
JsonNode ensureClientAuthorized(String outlet, String identifier);
JsonNode revokeClientFromOutlet(String outlet, String identifier);
void     deleteOutlet(String name);

JsonNode registerClient(String identifier, String label);
void     revokeClient(String identifier);
```

构造时打开一条到 `controller` outlet 的 Tunnel，把 `HttpClient` 指向本地 inlet。**线程安全**：`HttpClient` 自己是。`AutoCloseable` 保证 `try-with-resources` 自动清理。

### `OckamClient` 便利门面

```java
OckamClient.ConnectOptions opts = OckamClient.options();
opts.server = ServerConfig.parse("provider:14000");
opts.targetOutlet = "mysql";
opts.target       = "10.0.0.5:3306";              // 可选：自动 ensureOutlet
opts.adminIdentityName = "admin";                  // 与 target 配对
opts.appIdentityName   = "app";
opts.ockamHome    = Path.of("/var/lib/ockam-client");

try (Tunnel tun = OckamClient.connect(opts)) {
    ...
}
```

## 异常

```
OckamClientException                 // 根
├── OckamProcessException            // ockam CLI 出错
│       String getStderr();
│       Integer getReturncode();
├── OckamControllerException         // controller HTTP 非 2xx
│       int getStatusCode();
│       String getBody();
└── IdentityException                // identity / vault 相关
```

所有都是 `RuntimeException`，不强制 try/catch。但生产代码建议至少 `try { ... } catch (OckamClientException e) { log + alarm }`。

## 业务场景

### 场景 1：常驻服务 + JDBC 连接池

```java
public class DatabaseModule {
    private static final ServerConfig CFG = ServerConfig.parse("provider:14000");
    private static final Identity APP = Identity.load(Path.of("/var/lib/ockam-client"), "app");
    private static Tunnel tunnel;
    private static DataSource pool;

    public static synchronized DataSource pool() {
        if (pool == null) {
            tunnel = Tunnel.open(CFG, "mysql", APP);
            HikariConfig hc = new HikariConfig();
            hc.setJdbcUrl("jdbc:mysql://" + tunnel.host() + ":" + tunnel.port() + "/orders");
            hc.setMaximumPoolSize(20);
            pool = new HikariDataSource(hc);
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                try { ((HikariDataSource) pool).close(); } finally { tunnel.close(); }
            }));
        }
        return pool;
    }
}
```

### 场景 2：CLI / 批处理

```java
try (Tunnel tun = Tunnel.open(CFG, "mysql", APP);
     Connection c = DriverManager.getConnection(...)) {
    runEtl(c);
}
```

### 场景 3：动态切换数据源（多 outlet）

```java
try (Tunnel a = Tunnel.open(CFG, "mysql", APP);
     Tunnel b = Tunnel.open(CFG, "redis", APP)) {
    // 并发用 a / b
}
```

## 并发与线程

- `Tunnel` 是不可变（host/port 创建时定）+ AutoCloseable；多线程读 host/port 安全，多线程同时 close 不安全
- `ProviderAdmin` 内部 `HttpClient` 是线程安全的；多线程并发调 admin 方法可以
- 同一进程开多个 Tunnel 没问题，每个用独立 ockam node

## 超时

- secure-channel 握手默认 30s（`ServerConfig.connectTimeout`）
- HTTP 控制面默认 10s（`new ProviderAdmin(cfg, id, Duration.ofSeconds(20))`）
- ockam node 删除 30s（SDK 内部，超时静默吞）

## FAQ

**Q: HTTP/2 / HTTP/3 支持吗？**
A: 不支持。SDK 强制 HTTP/1.1（uvicorn 不能不带 TLS 跑 HTTP/2）。

**Q: 我能用 GraalVM native-image 吗？**
A: 应该可以——SDK 没用反射、没动态代理。Jackson 在 native-image 下需要少量配置；shaded jar 避免了这个的部分问题，但完整支持需要测试。

**Q: 内置 reactor / async API 吗？**
A: 当前不内置。`HttpClient` 本身有 `sendAsync`，可以包一层。如果有需求告诉我们再加。

**Q: 怎么调试 ockam 子进程？**
A: 设环境 `RUST_LOG=debug`，stderr 会写到 `OckamProcessException.getStderr()`。
