package com.ockam.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.ockam.client.exceptions.IdentityException;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * Handle on a local Ockam identity stored under OCKAM_HOME (a directory).
 * Vault state is managed by the ockam binary; we just shell out to it.
 */
public final class Identity {
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final Path home;
    private final String name;
    private final String identifier;

    private Identity(Path home, String name, String identifier) {
        this.home = home;
        this.name = name;
        this.identifier = identifier;
    }

    public Path home() { return home; }
    public String name() { return name; }
    public String identifier() { return identifier; }

    @Override
    public String toString() {
        return "Identity{name=" + name + ", id=" + identifier + ", home=" + home + "}";
    }

    /** Open OCKAM_HOME at `home`. Load existing identity or create one. */
    public static Identity loadOrCreate(Path home, String name) {
        try {
            Files.createDirectories(home);
        } catch (IOException e) {
            throw new IdentityException("cannot mkdir " + home, e);
        }

        // 1. Try to read existing
        try {
            ProcessRunner.Result r = ProcessRunner.run(
                home, List.of("identity", "show", "--output", "json"), 15);
            if (r.exitCode == 0 && !r.stdout.isBlank()) {
                String id = readIdentifier(r.stdout);
                if (id != null) return new Identity(home, name, id);
            }
        } catch (RuntimeException ignored) { /* fall through to create */ }

        // 2. Create
        ProcessRunner.Result rc = ProcessRunner.run(
            home, List.of("identity", "create", name), 20);
        if (rc.exitCode != 0) {
            throw new IdentityException("identity create failed: " + rc.stderr);
        }
        ProcessRunner.Result rs = ProcessRunner.run(
            home, List.of("identity", "show", "--output", "json"), 15);
        if (rs.exitCode != 0) {
            throw new IdentityException("identity show failed after create: " + rs.stderr);
        }
        String id = readIdentifier(rs.stdout);
        if (id == null) throw new IdentityException("identity show returned no identifier");
        return new Identity(home, name, id);
    }

    /** Open EXISTING identity. Throws if not present. */
    public static Identity load(Path home, String name) {
        if (!Files.isDirectory(home)) {
            throw new IdentityException("OCKAM_HOME does not exist: " + home);
        }
        ProcessRunner.Result r = ProcessRunner.run(
            home, List.of("identity", "show", "--output", "json"), 15);
        if (r.exitCode != 0) {
            throw new IdentityException("no identity in " + home + ": " + r.stderr);
        }
        String id = readIdentifier(r.stdout);
        if (id == null) throw new IdentityException("identity show returned no identifier");
        return new Identity(home, name, id);
    }

    private static String readIdentifier(String json) {
        try {
            JsonNode node = MAPPER.readTree(json);
            JsonNode i = node.get("identifier");
            return i == null ? null : i.asText();
        } catch (IOException e) {
            return null;
        }
    }
}
