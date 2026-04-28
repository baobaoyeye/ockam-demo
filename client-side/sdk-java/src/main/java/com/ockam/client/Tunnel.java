package com.ockam.client;

import com.ockam.client.exceptions.OckamProcessException;

import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Tunnel — encrypted tcp-inlet on localhost forwarding through an Ockam
 * secure channel to a remote tcp-outlet.
 *
 * Usage:
 *   try (Tunnel t = Tunnel.open(cfg, "mysql", appIdentity)) {
 *       try (Connection c = DriverManager.getConnection(
 *               "jdbc:mysql://" + t.host() + ":" + t.port() + "/db", ...)) {
 *           ...
 *       }
 *   }
 *
 * The Tunnel runs an ockam node bound to OS-assigned ephemeral ports;
 * `host()` is "127.0.0.1", `port()` is what ockam reported back.
 */
public final class Tunnel implements AutoCloseable {
    private static final Pattern INLET_RE = Pattern.compile(
        "(?:bound to|listening on|opened TCP listener|TCP inlet (?:created|listening) (?:at|on))\\s+" +
        "(?:tcp[:/]+)?(\\d{1,3}(?:\\.\\d{1,3}){3}|\\[?[0-9a-fA-F:]+\\]?):(\\d+)",
        Pattern.CASE_INSENSITIVE);
    private static final SecureRandom RNG = new SecureRandom();

    private final java.nio.file.Path home;
    private final String node;
    private final String host;
    private final int port;
    private boolean closed;

    private Tunnel(java.nio.file.Path home, String node, String host, int port) {
        this.home = home;
        this.node = node;
        this.host = host;
        this.port = port;
    }

    public String host() { return host; }
    public int port() { return port; }
    public String address() { return host + ":" + port; }

    public static Tunnel open(ServerConfig cfg, String targetOutlet, Identity identity) {
        return open(cfg, targetOutlet, identity, null);
    }

    public static Tunnel open(ServerConfig cfg, String targetOutlet, Identity identity, String nodeName) {
        if (nodeName == null || nodeName.isBlank()) {
            byte[] r = new byte[3]; RNG.nextBytes(r);
            String hex = String.format("%02x%02x%02x", r[0], r[1], r[2]);
            nodeName = "tun-" + ProcessHandle.current().pid() + "-" + hex;
        }
        java.nio.file.Path home = identity.home();
        // Idempotent: delete any leftover, then create
        ProcessRunner.run(home, List.of("node", "delete", nodeName, "--yes"), 10);
        ProcessRunner.Result rNode = ProcessRunner.run(home,
            List.of("node", "create", nodeName, "--tcp-listener-address", "127.0.0.1:0"), 20);
        if (rNode.exitCode != 0) {
            throw new OckamProcessException("node create failed", rNode.stderr, rNode.exitCode);
        }

        try {
            String sc = createSecureChannel(home, nodeName, cfg);
            int[] hp = createInlet(home, nodeName, sc, targetOutlet);
            return new Tunnel(home, nodeName, "127.0.0.1", hp[1]);
        } catch (RuntimeException e) {
            ProcessRunner.run(home, List.of("node", "delete", nodeName, "--yes"), 10);
            throw e;
        }
    }

    private static String createSecureChannel(java.nio.file.Path home, String node, ServerConfig cfg) {
        List<String> args = new ArrayList<>(List.of(
            "secure-channel", "create",
            "--from", "/node/" + node,
            "--to", "/dnsaddr/" + cfg.host() + "/tcp/" + cfg.port() + "/service/api"));
        if (cfg.expectedIdentifier() != null && !cfg.expectedIdentifier().isBlank()) {
            args.add("--authorized");
            args.add(cfg.expectedIdentifier());
        }
        ProcessRunner.Result r = ProcessRunner.run(home, args, (int) cfg.connectTimeout().getSeconds());
        if (r.exitCode != 0) {
            throw new OckamProcessException("secure-channel create failed", r.stderr, r.exitCode);
        }
        // Output: "/service/abcdef..." on its own line at end.
        String[] lines = r.stdout.split("\\r?\\n");
        for (int i = lines.length - 1; i >= 0; i--) {
            String ln = lines[i].trim();
            if (ln.startsWith("/service/") || ln.startsWith("/node/")) return ln;
        }
        throw new OckamProcessException(
            "could not parse secure-channel route", r.stdout + "\n---\n" + r.stderr, r.exitCode);
    }

    private static int[] createInlet(java.nio.file.Path home, String node, String sc, String target) {
        ProcessRunner.Result r = ProcessRunner.run(home, List.of(
            "tcp-inlet", "create",
            "--at", node,
            "--from", "127.0.0.1:0",
            "--to", sc + "/service/" + target), 20);
        if (r.exitCode != 0) {
            throw new OckamProcessException("tcp-inlet create failed", r.stderr, r.exitCode);
        }
        String merged = r.stdout + "\n" + r.stderr;
        Matcher m = INLET_RE.matcher(merged);
        if (m.find()) {
            return new int[]{0, Integer.parseInt(m.group(2))};
        }
        // Some versions print the bare "127.0.0.1:NNNN"
        for (String ln : merged.split("\\r?\\n")) {
            ln = ln.trim();
            int idx = ln.lastIndexOf(':');
            if (idx > 0) {
                String port = ln.substring(idx + 1);
                if (port.matches("\\d+")) {
                    return new int[]{0, Integer.parseInt(port)};
                }
            }
        }
        throw new OckamProcessException("could not parse tcp-inlet bound address", merged, r.exitCode);
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        // node delete can be slow under load; swallow timeouts so close()
        // never throws — leaves the node behind only briefly until the next
        // open() reuses or deletes it.
        try {
            ProcessRunner.run(home, List.of("node", "delete", node, "--yes"), 30);
        } catch (RuntimeException ignored) {
        }
    }
}
