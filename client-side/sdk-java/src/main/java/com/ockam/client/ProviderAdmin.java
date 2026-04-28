package com.ockam.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.ockam.client.exceptions.OckamControllerException;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * ProviderAdmin — talk to ockam-server's controller HTTP API through a
 * Tunnel to the `controller` outlet.
 *
 * Use as try-with-resources:
 *   try (ProviderAdmin admin = new ProviderAdmin(cfg, identity)) {
 *       admin.ensureOutlet("mysql", "10.0.0.5:3306");
 *   }
 */
public final class ProviderAdmin implements AutoCloseable {
    private static final String CONTROLLER_OUTLET = "controller";
    private static final ObjectMapper M = new ObjectMapper();

    private final Tunnel tunnel;
    private final HttpClient http;
    private final URI base;
    private final String myIdentifier;
    private final Duration timeout;
    private boolean closed;

    public ProviderAdmin(ServerConfig cfg, Identity identity) {
        this(cfg, identity, Duration.ofSeconds(10));
    }

    public ProviderAdmin(ServerConfig cfg, Identity identity, Duration timeout) {
        this.tunnel = Tunnel.open(cfg, CONTROLLER_OUTLET, identity);
        this.timeout = timeout;
        this.base = URI.create("http://" + tunnel.host() + ":" + tunnel.port());
        this.myIdentifier = identity.identifier();
        // Force HTTP/1.1: uvicorn-on-loopback doesn't speak HTTP/2 plain-text,
        // and Java's HttpClient picks HTTP/2 by default when no TLS is involved.
        this.http = HttpClient.newBuilder()
                              .version(HttpClient.Version.HTTP_1_1)
                              .connectTimeout(Duration.ofSeconds(5))
                              .build();
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        tunnel.close();
    }

    // ---------- read endpoints ---------------------------------------------
    public JsonNode healthz() { return get("/healthz"); }
    public JsonNode info()    { return get("/info"); }
    public JsonNode listOutlets() { return get("/outlets"); }
    public JsonNode listClients() { return get("/clients"); }

    // ---------- write endpoints --------------------------------------------
    public JsonNode ensureOutlet(String name, String target) {
        return ensureOutlet(name, target, java.util.List.of());
    }

    public JsonNode ensureOutlet(String name, String target, java.util.List<String> allow) {
        ObjectNode body = M.createObjectNode();
        body.put("name", name);
        body.put("target", target);
        ArrayNode arr = body.putArray("allow");
        for (String a : allow) arr.add(a);
        return post("/outlets", body);
    }

    public JsonNode ensureClientAuthorized(String outlet, String identifier) {
        ObjectNode body = M.createObjectNode();
        ArrayNode add = body.putArray("allow_add");
        add.add(identifier);
        return patch("/outlets/" + outlet, body);
    }

    public JsonNode revokeClientFromOutlet(String outlet, String identifier) {
        ObjectNode body = M.createObjectNode();
        ArrayNode rem = body.putArray("allow_remove");
        rem.add(identifier);
        return patch("/outlets/" + outlet, body);
    }

    public void deleteOutlet(String name) {
        delete("/outlets/" + name);
    }

    public JsonNode registerClient(String identifier, String label) {
        ObjectNode body = M.createObjectNode();
        body.put("identifier", identifier);
        body.put("label", label == null ? "" : label);
        return post("/clients", body);
    }

    public void revokeClient(String identifier) {
        delete("/clients/" + identifier);
    }

    // ---------- internals ---------------------------------------------------
    private HttpRequest.Builder reqBuilder(String path) {
        return HttpRequest.newBuilder()
                .uri(base.resolve(path))
                .header("X-Ockam-Remote-Identifier", myIdentifier)
                .timeout(timeout);
    }

    private JsonNode get(String path) {
        return send(reqBuilder(path).GET().build(), "GET " + path);
    }

    private JsonNode post(String path, ObjectNode body) {
        try {
            String json = M.writeValueAsString(body);
            return send(reqBuilder(path)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(json)).build(),
                "POST " + path);
        } catch (IOException e) {
            throw new OckamControllerException("json encode failed", -1, e.getMessage());
        }
    }

    private JsonNode patch(String path, ObjectNode body) {
        try {
            String json = M.writeValueAsString(body);
            return send(reqBuilder(path)
                .header("Content-Type", "application/json")
                .method("PATCH", HttpRequest.BodyPublishers.ofString(json)).build(),
                "PATCH " + path);
        } catch (IOException e) {
            throw new OckamControllerException("json encode failed", -1, e.getMessage());
        }
    }

    private void delete(String path) {
        send(reqBuilder(path).DELETE().build(), "DELETE " + path);
    }

    private JsonNode send(HttpRequest req, String label) {
        HttpResponse<String> resp;
        try {
            resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        } catch (Exception e) {
            throw new OckamControllerException(label + " network error: " + e.getMessage(),
                                                -1, e.getMessage());
        }
        int sc = resp.statusCode();
        if (sc < 200 || sc >= 300) {
            String bodyHint = resp.body() == null ? "" : resp.body();
            if (bodyHint.length() > 400) bodyHint = bodyHint.substring(0, 400) + "...";
            throw new OckamControllerException(label + " failed: HTTP " + sc + " body=" + bodyHint,
                                               sc, resp.body());
        }
        if (sc == 204 || resp.body() == null || resp.body().isEmpty()) {
            return M.nullNode();
        }
        try {
            return M.readTree(resp.body());
        } catch (IOException e) {
            throw new OckamControllerException(
                label + " returned non-JSON: " + e.getMessage(), sc, resp.body());
        }
    }
}
