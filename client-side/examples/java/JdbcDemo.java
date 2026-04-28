import com.ockam.client.Identity;
import com.ockam.client.ProviderAdmin;
import com.ockam.client.ServerConfig;
import com.ockam.client.Tunnel;

import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;

/**
 * Mirror of python_mysql.py: ensure outlet, open tunnel, run real SQL.
 *
 * Reads connection info from env. Prints PASS/FAIL on stdout.
 */
public class JdbcDemo {

    public static void main(String[] args) throws Exception {
        ServerConfig cfg = ServerConfig.builder()
                .host(env("OCKAM_SERVER_HOST"))
                .port(Integer.parseInt(env("OCKAM_SERVER_PORT", "14000")))
                .build();
        Path ockamHome = Path.of(env("OCKAM_HOME", "/var/lib/ockam-client"));
        String outletName = env("OCKAM_OUTLET", "mysql");
        String upstream   = env("OCKAM_UPSTREAM", "mysql:3306");

        String dbUser = env("MYSQL_USER", "demo");
        String dbPwd  = env("MYSQL_PASSWORD", "demopw");
        String dbName = env("MYSQL_DATABASE", "demo");

        // 1. admin → ensure outlet
        Identity adminId = Identity.loadOrCreate(ockamHome, "admin");
        System.out.println("[client] admin identifier: " + adminId.identifier());

        try (ProviderAdmin admin = new ProviderAdmin(cfg, adminId)) {
            System.out.println("[client] info: " + admin.info());
            admin.ensureOutlet(outletName, upstream, java.util.List.of(adminId.identifier()));
            System.out.println("[client] outlets: " + admin.listOutlets());
        }

        // 2. data tunnel + JDBC
        try (Tunnel tun = Tunnel.open(cfg, outletName, adminId)) {
            System.out.println("[client] tunnel: " + tun.address() + " -> " + outletName);

            String url = "jdbc:mysql://" + tun.host() + ":" + tun.port() + "/" + dbName
                       + "?useSSL=false&allowPublicKeyRetrieval=true";

            // tiny retry loop while inlet warms up
            Connection conn = null;
            Exception last = null;
            for (int i = 0; i < 10; i++) {
                try { conn = DriverManager.getConnection(url, dbUser, dbPwd); break; }
                catch (Exception e) { last = e; Thread.sleep(1000); }
            }
            if (conn == null) throw new RuntimeException("could not connect through tunnel: " + last);

            try (Connection c = conn) {
                String secret = "PLAINTEXT_SECRET_VIA_OCKAM_JAVA_AT_" + System.currentTimeMillis();
                try (PreparedStatement ins = c.prepareStatement(
                        "INSERT INTO messages (sender, content) VALUES (?, ?)")) {
                    ins.setString(1, "java-sdk");
                    ins.setString(2, secret);
                    ins.executeUpdate();
                }
                System.out.println("[client] inserted: " + secret);

                try (Statement st = c.createStatement();
                     ResultSet rs = st.executeQuery(
                         "SELECT id, sender, content FROM messages ORDER BY id")) {
                    System.out.println("[client] rows in `messages`:");
                    while (rs.next()) {
                        System.out.printf("  id=%d sender=%s content=%s%n",
                            rs.getInt(1), rs.getString(2), rs.getString(3));
                    }
                }
            }
        }
        System.out.println("[client] DONE");
    }

    private static String env(String k) {
        String v = System.getenv(k);
        if (v == null) throw new RuntimeException("missing env: " + k);
        return v;
    }
    private static String env(String k, String def) {
        String v = System.getenv(k);
        return v == null ? def : v;
    }
}
