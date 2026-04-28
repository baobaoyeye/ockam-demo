# SDK.md — ockam-controller HTTP API 规范

面向 SDK / 集成开发者：你要怎么调这个控制面、每个端点的契约、错误怎么处理。

部署文档见 [DEPLOY.md](DEPLOY.md)。

## Base URL

- 生产：通过 ockam tunnel 访问。SDK 先开一个到 `controller` outlet 的 Ockam 通道，得到本地 inlet 端口 `127.0.0.1:<auto-port>`，base URL 即 `http://127.0.0.1:<auto-port>`。
- 测试：直接 `http://<host>:8080`。

## 鉴权 header

| 场景 | header |
|------|--------|
| 通过 Ockam tunnel | controller 自动信任 outlet 注入的 `X-Ockam-Remote-Identifier: I...` |
| Bootstrap | `Authorization: Bearer <bootstrap_token>` |
| 本地测试 | 无（设 `OCKAM_CONTROLLER_TRUST_ALL=1`） |

## 端点

### `GET /healthz`

无需鉴权。健康检查。

**响应 200**:
```json
{
  "status": "ok",
  "ockam_node": "running",
  "outlets_total": 2,
  "outlets_ok": 2,
  "version": "0.1.0"
}
```

字段：
- `status`: `ok` / `degraded` / `down`
- `ockam_node`: `running` / `missing`
- `outlets_total`: 状态文件里有几个 outlet
- `outlets_ok`: 真正在 ockam node 上 ready 的有几个
- `version`: controller 版本

### `GET /info`

无需鉴权。节点信息。

**响应 200**:
```json
{
  "node_name": "provider",
  "identifier": "I3a6cf971d6659a23d72204a36577cc489286e01426d98bdb6defdd4ce06672d",
  "transport": "0.0.0.0:14000",
  "version": "0.1.0"
}
```

`identifier` 是服务端 ockam node 的身份。客户端 SDK 应该 pin 这个值，对外发起的 secure-channel 用 `--authorized` 钉死它，防止中间人。

### `GET /outlets`

需要 client 或 admin。列出所有 outlet。

**响应 200**:
```json
[
  {
    "name": "mysql",
    "target": "10.0.0.5:3306",
    "allow": [
      {
        "identifier": "I7c91d77a98...",
        "label": "app-prod-1",
        "added_at": "2026-04-25T10:30:00Z"
      }
    ],
    "state": "ready"
  }
]
```

`state`: `ready` / `pending` / `error: <msg>`

### `POST /outlets`

需要 admin。**Upsert** 一个 outlet（同名重复创建不会 409，会更新 target 并合并 allow 列表）。

**请求体**:
```json
{
  "name": "mysql",            // /^[a-zA-Z0-9_-]{1,64}$/
  "target": "10.0.0.5:3306",  // host:port
  "allow": ["I7c91d..."]      // 可选，初始允许列表；空 = deny all
}
```

**响应 201**: `OutletView`（同 GET）

**错误**:
- `400` 入参不符合 schema（pydantic 错误明细在 detail）
- `403` 调用者非 admin
- `500` ockam node 应用 outlet 失败 (`outlet apply failed: ...`)，state 已写但 outlet `state` 字段会是 `error: ...`

### `GET /outlets/{name}`

需要 client 或 admin。

**响应 200**: `OutletView`
**404**: outlet 不存在

### `PATCH /outlets/{name}`

需要 admin。增量改 outlet。

**请求体**（所有字段可选）:
```json
{
  "target": "10.0.0.6:3306",
  "allow_add":    ["I8d12e..."],
  "allow_remove": ["I7c91d..."]
}
```

**响应 200**: `OutletView`

### `DELETE /outlets/{name}`

需要 admin。删除 outlet（状态 + 实际 ockam outlet）。

**响应 204** / **404**

### `GET /clients`

需要 client 或 admin。列出已注册的客户端身份（不一定授权了任何 outlet）。

**响应 200**: `[ClientRef...]`

### `POST /clients`

需要 admin。注册一个 identifier。**仅记录**，授权要单独 `PATCH /outlets/<name>` 加到 `allow_add`。

**请求体**:
```json
{
  "identifier": "I8d12e...",
  "label": "data-pipeline-job-7"
}
```

**响应 201**: `ClientRef`

### `DELETE /clients/{identifier}`

需要 admin。撤销一个客户端。**会从所有 outlet 的 allow 列表里也移除**。

**响应 204** / **404**

### `GET /audit?since=<iso8601>`

需要 client 或 admin。最近 200 条事件（环形缓冲）。

**响应 200**:
```json
[
  {
    "ts": "2026-04-25T10:30:00.123Z",
    "event": "outlet_upserted",
    "detail": {"name": "mysql", "target": "10.0.0.5:3306"}
  }
]
```

事件类型：`outlet_upserted` / `outlet_patched` / `outlet_deleted` / `client_registered` / `client_revoked`

## 幂等性

- `POST /outlets` 同名 = upsert；安全重复
- `POST /clients` 同 identifier = 更新 label；安全重复
- `DELETE` 操作返回 404 表示幂等成功（资源已经不在了）

## 错误响应统一格式

```json
{
  "detail": "outlet apply failed: tcp-outlet name already used"
}
```

或 pydantic 校验错误：

```json
{
  "detail": [
    {"loc": ["body", "target"], "msg": "target must be 'host:port' with numeric port", "type": "value_error"}
  ]
}
```

## SDK 集成示例（Python）

```python
import requests

BASE = "http://127.0.0.1:18080"   # 经 ockam tunnel 接入的 base
HEADERS = {"X-Ockam-Remote-Identifier": "I_admin_xxx"}

# Ensure outlet
requests.post(f"{BASE}/outlets", json={
    "name": "mysql",
    "target": "10.0.0.5:3306",
    "allow": ["I_app_xxx"],
}, headers=HEADERS).raise_for_status()

# 增加新客户端授权
requests.patch(f"{BASE}/outlets/mysql", json={
    "allow_add": ["I_app_yyy"],
}, headers=HEADERS).raise_for_status()

# 列状态
print(requests.get(f"{BASE}/outlets", headers=HEADERS).json())
```

## SDK 集成示例（Java）

```java
HttpClient http = HttpClient.newHttpClient();
String body = """
  {"name":"mysql","target":"10.0.0.5:3306","allow":["I_app_xxx"]}""";
HttpRequest req = HttpRequest.newBuilder()
    .uri(URI.create("http://127.0.0.1:18080/outlets"))
    .header("Content-Type", "application/json")
    .header("X-Ockam-Remote-Identifier", "I_admin_xxx")
    .POST(HttpRequest.BodyPublishers.ofString(body))
    .build();
HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
if (resp.statusCode() != 201) throw new RuntimeException(resp.body());
```

> 实际开发不必直接调 HTTP；用 [client-side/sdk-python](../../client-side/sdk-python/) 的 `ProviderAdmin` 或 [sdk-java](../../client-side/sdk-java/) 的 `ProviderAdmin` 类，它们已经封装好 tunnel + auth + 重试。
