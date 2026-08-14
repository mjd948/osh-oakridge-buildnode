package com.botts.oscar.ctl;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/**
 * Installation settings, layered so that an operator can change any of them without
 * editing a shipped file.
 *
 * <p>Precedence, highest first: environment variable, then {@code oscar.env} in the
 * config directory, then the built-in default.
 */
public final class Settings {

    private final Properties file = new Properties();
    private final OscarPaths paths;

    Settings(OscarPaths paths) {
        this.paths = paths;
        Path envFile = paths.config().resolve("oscar.env");
        if (Files.isReadable(envFile)) {
            try (InputStream in = Files.newInputStream(envFile)) {
                file.load(in);
            } catch (IOException e) {
                System.err.println("Warning: could not read " + envFile + ": " + e.getMessage());
            }
        }
    }

    private String get(String key, String fallback) {
        String env = System.getenv(key);
        if (env != null && !env.isBlank())
            return env.trim();
        String prop = file.getProperty(key);
        if (prop != null && !prop.isBlank())
            return prop.trim();
        return fallback;
    }

    public String dbHost() {
        return get("OSCAR_DB_HOST", "localhost");
    }

    public int dbPort() {
        return Integer.parseInt(get("OSCAR_DB_PORT", "5432"));
    }

    public String dbName() {
        return get("OSCAR_DB_NAME", "gis");
    }

    public String dbUser() {
        return get("OSCAR_DB_USER", "postgres");
    }

    public String dbPassword() {
        return get("OSCAR_DB_PASSWORD", "postgres");
    }

    public String dbListenAddresses() {
        return get("OSCAR_DB_LISTEN", "127.0.0.1");
    }

    public int dbMaxConnections() {
        // The containerised configuration used 1024. That is far more than the node's
        // connection pools need and each backend reserves memory, so the default is
        // reduced here; raise it in oscar.local.conf if a large site genuinely needs it.
        return Integer.parseInt(get("OSCAR_DB_MAX_CONNECTIONS", "200"));
    }

    public String logDir() {
        return get("OSCAR_LOG_DIR", paths.data().resolve("log").toString());
    }

    /**
     * The initial admin password, used exactly once when config.json is first rendered.
     * There is deliberately no default: shipping a product whose admin password is
     * "admin" unless someone remembers to change it is not a defensible position.
     */
    public String initialAdminPassword() throws IOException {
        String env = System.getenv("OSCAR_ADMIN_PASSWORD");
        if (env != null && !env.isBlank())
            return env.trim();

        Path pwFile = paths.config().resolve("admin-password");
        if (Files.isReadable(pwFile)) {
            String value = Files.readString(pwFile, StandardCharsets.UTF_8).trim();
            if (!value.isBlank())
                return value;
        }

        throw new IllegalStateException(
                "No initial admin password provided.\n"
                + "Set OSCAR_ADMIN_PASSWORD, or write one to " + pwFile + " (mode 0600).\n"
                + "Refusing to fall back to a default password.");
    }
}
