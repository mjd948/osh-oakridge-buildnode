package com.botts.oscar.ctl;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Resolves the three roots an OSCAR install is built from.
 *
 * <p>The program directory is immutable and replaced wholesale on upgrade. The config
 * and data directories belong to the operator and must survive it. Keeping them apart
 * is what makes an upgrade safe; every path used by the rest of oscarctl is derived
 * from here rather than assumed relative to the current working directory.
 */
public final class OscarPaths {

    private final Path home;
    private final Path config;
    private final Path data;

    private OscarPaths(Path home, Path config, Path data) {
        this.home = home;
        this.config = config;
        this.data = data;
    }

    /**
     * Resolves the roots from the environment, falling back to a layout that works
     * when an operator has simply unpacked the archive and is running in place.
     */
    public static OscarPaths fromEnvironment() {
        Path home = fromEnv("OSCAR_HOME", defaultHome());
        Path data = fromEnv("OSCAR_DATA", home.resolve("data"));
        Path config = fromEnv("OSCAR_CONFIG", home.resolve("config"));
        return new OscarPaths(home, config, data);
    }

    private static Path fromEnv(String var, Path fallback) {
        String value = System.getenv(var);
        if (value == null || value.isBlank())
            return fallback.toAbsolutePath().normalize();
        return Paths.get(value).toAbsolutePath().normalize();
    }

    /**
     * When OSCAR_HOME is unset, locate the install from this jar's own position:
     * it lives in {@code <home>/lib/oscarctl.jar}.
     */
    private static Path defaultHome() {
        try {
            Path jar = Paths.get(OscarPaths.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
            if (Files.isRegularFile(jar) && jar.getParent() != null
                    && jar.getParent().getFileName().toString().equals("lib")) {
                return jar.getParent().getParent();
            }
        } catch (Exception ignored) {
            // Fall through to the working directory.
        }
        return Paths.get("").toAbsolutePath();
    }

    /** Immutable program directory: lib/, pgsql/, web/, models/, jre/. */
    public Path home() {
        return home;
    }

    /** Operator-owned configuration that survives upgrades. */
    public Path config() {
        return config;
    }

    /** Mutable state: pgdata/ and the node working directory. */
    public Path data() {
        return data;
    }

    /** The PostgreSQL cluster directory. */
    public Path pgData() {
        return data.resolve("pgdata");
    }

    /** The node's working directory; everything OSCAR reads relatively lives here. */
    public Path nodeDir() {
        return data.resolve("node");
    }

    /** True when running on Windows, where the bundled tree and process model differ. */
    public static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase().contains("win");
    }

    /**
     * Directory holding the bundled PostgreSQL binaries.
     *
     * <p>The two platform bundles have different shapes and both are legitimate. The
     * Linux bundle is derived from Debian packages and keeps Debian's split layout
     * ({@code usr/lib/postgresql/<major>/bin}), which must be preserved because
     * PostgreSQL locates its share directory by reproducing the configured bin-to-share
     * relationship from the running binary's real path. The Windows bundle comes from
     * EDB's binaries zip, which uses a conventional flat prefix. Detect rather than
     * assume.
     */
    public Path pgBin() {
        Path flat = home.resolve("pgsql/bin");
        if (Files.isDirectory(flat))
            return flat;
        return home.resolve("pgsql/usr/lib/postgresql/" + Postgres.MAJOR_VERSION + "/bin");
    }

    /** Resolves a PostgreSQL executable, adding the .exe suffix where required. */
    public Path pgExe(String name) {
        return pgBin().resolve(isWindows() ? name + ".exe" : name);
    }

    /**
     * Unix socket directory for the embedded cluster, or null on Windows, which has no
     * Unix sockets and rejects the corresponding setting outright.
     */
    public Path pgSocketDir() {
        return isWindows() ? null : data.resolve("run");
    }

    @Override
    public String toString() {
        return "home=" + home + " config=" + config + " data=" + data;
    }
}
