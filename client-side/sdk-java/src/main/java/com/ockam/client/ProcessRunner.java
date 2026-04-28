package com.ockam.client;

import com.ockam.client.exceptions.OckamProcessException;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Synchronously run the `ockam` binary, capturing stdout/stderr. */
final class ProcessRunner {
    private ProcessRunner() {}

    public static class Result {
        public final int exitCode;
        public final String stdout;
        public final String stderr;
        public Result(int exitCode, String stdout, String stderr) {
            this.exitCode = exitCode;
            this.stdout = stdout;
            this.stderr = stderr;
        }
    }

    /** Run `ockam <args...>` with OCKAM_HOME=home. timeoutSeconds 0 = no timeout. */
    public static Result run(Path home, List<String> args, int timeoutSeconds) {
        String binary = System.getenv().getOrDefault("OCKAM_BINARY", "ockam");
        List<String> cmd = new ArrayList<>();
        cmd.add(binary);
        cmd.addAll(args);

        ProcessBuilder pb = new ProcessBuilder(cmd);
        Map<String, String> env = pb.environment();
        env.put("OCKAM_HOME", home.toString());
        pb.redirectErrorStream(false);

        Process p;
        try {
            p = pb.start();
        } catch (IOException e) {
            throw new OckamProcessException(
                "could not start " + binary + ": " + e.getMessage(),
                "", null, e);
        }

        Thread outReader = startReader(p.getInputStream(), "stdout-" + binary);
        Thread errReader = startReader(p.getErrorStream(), "stderr-" + binary);

        try {
            boolean done;
            if (timeoutSeconds > 0) {
                done = p.waitFor(timeoutSeconds, TimeUnit.SECONDS);
            } else {
                p.waitFor();
                done = true;
            }
            if (!done) {
                p.destroyForcibly();
                throw new OckamProcessException(
                    "ockam " + String.join(" ", args) + " timed out after " + timeoutSeconds + "s",
                    "", null);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            p.destroyForcibly();
            throw new OckamProcessException("interrupted waiting for ockam", "", null, e);
        }

        outReader.interrupt();
        errReader.interrupt();
        try { outReader.join(2000); errReader.join(2000); } catch (InterruptedException ignored) {}

        return new Result(p.exitValue(), getCapture(outReader), getCapture(errReader));
    }

    private static Thread startReader(java.io.InputStream is, String name) {
        StringBuilder sb = new StringBuilder();
        Thread t = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                    sb.append(line).append('\n');
                }
            } catch (IOException ignored) {}
        }, name);
        t.setDaemon(true);
        // Hide capture buffer in thread name for retrieval (stupid but avoids extra class)
        Captures.put(t, sb);
        t.start();
        return t;
    }

    private static String getCapture(Thread t) {
        StringBuilder sb = Captures.remove(t);
        return sb == null ? "" : sb.toString();
    }

    private static class Captures {
        private static final java.util.WeakHashMap<Thread, StringBuilder> map = new java.util.WeakHashMap<>();
        public static synchronized void put(Thread t, StringBuilder sb) { map.put(t, sb); }
        public static synchronized StringBuilder remove(Thread t) { return map.remove(t); }
    }
}
