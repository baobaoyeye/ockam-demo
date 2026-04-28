package com.ockam.client;

import java.time.Duration;

/** How to reach a deployed ockam-server. Use the builder. */
public final class ServerConfig {
    public static final int DEFAULT_PORT = 14000;

    private final String host;
    private final int port;
    private final String expectedIdentifier;   // optional, pin identity
    private final Duration connectTimeout;

    private ServerConfig(Builder b) {
        if (b.host == null || b.host.isBlank()) {
            throw new IllegalArgumentException("host required");
        }
        this.host = b.host;
        this.port = b.port;
        this.expectedIdentifier = b.expectedIdentifier;
        this.connectTimeout = b.connectTimeout;
    }

    public String host() { return host; }
    public int port() { return port; }
    public String expectedIdentifier() { return expectedIdentifier; }
    public Duration connectTimeout() { return connectTimeout; }
    public String address() { return host + ":" + port; }

    public static Builder builder() { return new Builder(); }

    /** Parse a "host:port" string. Port defaults to 14000 if not present. */
    public static ServerConfig parse(String hostPort) {
        if (hostPort == null || hostPort.isBlank()) {
            throw new IllegalArgumentException("hostPort required");
        }
        int idx = hostPort.lastIndexOf(':');
        if (idx < 0) {
            return builder().host(hostPort).build();
        }
        String h = hostPort.substring(0, idx);
        int p = Integer.parseInt(hostPort.substring(idx + 1));
        return builder().host(h).port(p).build();
    }

    public static final class Builder {
        private String host;
        private int port = DEFAULT_PORT;
        private String expectedIdentifier;
        private Duration connectTimeout = Duration.ofSeconds(30);

        public Builder host(String host) { this.host = host; return this; }
        public Builder port(int port) { this.port = port; return this; }
        public Builder server(String host, int port) {
            this.host = host; this.port = port; return this;
        }
        public Builder expectedIdentifier(String id) { this.expectedIdentifier = id; return this; }
        public Builder connectTimeout(Duration d) { this.connectTimeout = d; return this; }

        public ServerConfig build() { return new ServerConfig(this); }
    }
}
