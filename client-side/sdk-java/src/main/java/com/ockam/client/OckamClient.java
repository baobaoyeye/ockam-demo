package com.ockam.client;

import java.nio.file.Path;

/** Top-level convenience facade — mirrors Python's `connect(...)`. */
public final class OckamClient {
    private OckamClient() {}

    public static class ConnectOptions {
        public ServerConfig server;
        public String targetOutlet;
        public String target;                  // "host:port" upstream; null = skip ensureOutlet
        public Path  ockamHome = Path.of("/var/lib/ockam-client");
        public String appIdentityName = "app";
        public String adminIdentityName;       // null = skip ensureOutlet
        public String expectedIdentifier;      // null = no MITM-pinning
    }

    /**
     * Open a Tunnel to a remote outlet. If `target` and `adminIdentityName`
     * are provided, ensures the outlet exists/maps to that target first.
     *
     * Returns a Tunnel — use it as try-with-resources.
     */
    public static Tunnel connect(ConnectOptions o) {
        if (o.server == null) throw new IllegalArgumentException("server required");
        if (o.targetOutlet == null) throw new IllegalArgumentException("targetOutlet required");

        ServerConfig cfg = o.server;
        if (o.expectedIdentifier != null && !o.expectedIdentifier.isBlank()) {
            cfg = ServerConfig.builder()
                    .host(cfg.host()).port(cfg.port())
                    .expectedIdentifier(o.expectedIdentifier)
                    .connectTimeout(cfg.connectTimeout())
                    .build();
        }

        Identity appId = Identity.loadOrCreate(o.ockamHome, o.appIdentityName);

        if (o.target != null && o.adminIdentityName != null) {
            Identity adminId = Identity.loadOrCreate(o.ockamHome, o.adminIdentityName);
            try (ProviderAdmin admin = new ProviderAdmin(cfg, adminId)) {
                admin.ensureOutlet(o.targetOutlet, o.target,
                                   java.util.List.of(appId.identifier()));
            }
        }

        return Tunnel.open(cfg, o.targetOutlet, appId);
    }

    /** Builder-style sugar. */
    public static ConnectOptions options() { return new ConnectOptions(); }
}
