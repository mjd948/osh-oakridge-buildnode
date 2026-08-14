package com.botts.oscar.ctl;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;

/**
 * Drives the bundled PostgreSQL: cluster creation, configuration, readiness and
 * extension installation.
 *
 * <p>All database work goes over JDBC rather than by shelling out to {@code psql},
 * so nothing here depends on a client being present on PATH.
 */
public final class Postgres {

    /** Major version of the bundled server. A cluster from another major cannot be opened. */
    public static final int MAJOR_VERSION = 16;

    /** Extensions OSCAR's datastore relies on. Matches the live production database. */
    static final List<String> REQUIRED_EXTENSIONS = List.of(
            "pg_trgm", "btree_gist", "btree_gin", "fuzzystrmatch",
            "postgis", "postgis_topology", "postgis_tiger_geocoder");

    private final OscarPaths paths;
    private final Settings settings;

    Postgres(OscarPaths paths, Settings settings) {
        this.paths = paths;
        this.settings = settings;
    }

    // ---------------------------------------------------------------- cluster

    boolean clusterExists() {
        return Files.isRegularFile(paths.pgData().resolve("PG_VERSION"));
    }

    /**
     * Reads the major version of an existing cluster. Opening a data directory with a
     * server of a different major version is not supported by PostgreSQL and would
     * either fail confusingly or, far worse, tempt an installer into re-initialising
     * over live data.
     */
    private String existingClusterVersion() throws IOException {
        return Files.readString(paths.pgData().resolve("PG_VERSION"), StandardCharsets.UTF_8).trim();
    }

    void assertClusterVersionMatches() throws IOException {
        if (!clusterExists())
            return;
        String found = existingClusterVersion();
        if (!found.equals(String.valueOf(MAJOR_VERSION))) {
            throw new IllegalStateException(
                    "Existing database at " + paths.pgData() + " was created by PostgreSQL "
                    + found + ", but this build bundles PostgreSQL " + MAJOR_VERSION + ".\n"
                    + "Refusing to touch it. Migrating across major versions requires pg_upgrade;\n"
                    + "re-initialising would destroy the existing data.");
        }
    }

    /** Creates the cluster if absent. Safe to run on every service start. */
    void initCluster() throws Exception {
        assertClusterVersionMatches();
        if (clusterExists()) {
            System.out.println("Cluster already present at " + paths.pgData() + " (PostgreSQL "
                    + existingClusterVersion() + "); leaving it alone.");
            writeManagedConfig();
            return;
        }

        Files.createDirectories(paths.pgData().getParent());
        if (paths.pgSocketDir() != null)
            Files.createDirectories(paths.pgSocketDir());

        Path pwFile = Files.createTempFile("oscar-initdb", ".pw");
        try {
            Files.writeString(pwFile, settings.dbPassword(), StandardCharsets.UTF_8);
            restrictToOwner(pwFile);

            System.out.println("Initialising PostgreSQL cluster at " + paths.pgData());
            List<String> cmd = new ArrayList<>(List.of(
                    paths.pgExe("initdb").toString(),
                    "-D", paths.pgData().toString(),
                    "-U", settings.dbUser(),
                    "--encoding=UTF8",
                    "--locale=C",
                    "--auth-host=scram-sha-256",
                    "--pwfile=" + pwFile.toString()));
            // Local (Unix-socket) authentication does not exist on Windows. Appended
            // rather than inserted: initdb takes these options in any order, and an
            // index-based insert would land between -U and its value.
            if (!OscarPaths.isWindows())
                cmd.add("--auth-local=trust");
            Proc.run(cmd.toArray(new String[0]));
        } finally {
            Files.deleteIfExists(pwFile);
        }
        restrictToOwner(paths.pgData());
        writeManagedConfig();
    }

    /**
     * Writes OSCAR's tuning into its own file and includes it from postgresql.conf.
     *
     * <p>Deliberately not {@code ALTER SYSTEM}: that writes postgresql.auto.conf, which
     * takes precedence over postgresql.conf, so any setting an upgrade later tried to
     * change would be silently overridden by the value written at first install. A
     * managed include file can be rewritten on every upgrade, and the sibling
     * {@code oscar.local.conf} gives the operator a place to override us that we
     * will never touch.
     */
    private void writeManagedConfig() throws IOException {
        Path pgConf = paths.pgData().resolve("postgresql.conf");
        Path managed = paths.pgData().resolve("oscar.conf");
        Path local = paths.pgData().resolve("oscar.local.conf");

        long ramMb = SystemMemory.totalMegabytes();
        long sharedBuffersMb = Math.max(128, Math.min(ramMb / 4, 4096));
        long maintenanceMb = Math.max(64, Math.min(ramMb / 16, 2048));

        String body = String.join(System.lineSeparator(),
                "# Managed by OSCAR. Rewritten on upgrade - put local overrides in oscar.local.conf.",
                "listen_addresses = '" + settings.dbListenAddresses() + "'",
                "port = " + settings.dbPort(),
                // Windows has no Unix sockets and rejects this setting.
                paths.pgSocketDir() != null
                        ? "unix_socket_directories = '" + paths.pgSocketDir() + "'"
                        : "# unix_socket_directories: not applicable on Windows",
                "max_connections = " + settings.dbMaxConnections(),
                "shared_buffers = " + sharedBuffersMb + "MB",
                "maintenance_work_mem = " + maintenanceMb + "MB",
                // Retained from the original containerised configuration. Left in place
                // deliberately rather than dropped, but it does cap query parallelism.
                "max_parallel_workers = 0",
                "max_parallel_workers_per_gather = 0",
                // The JIT libraries are not shipped, so this must stay off.
                "jit = off",
                "logging_collector = on",
                "log_directory = '" + settings.logDir() + "'",
                "log_filename = 'postgresql-%a.log'",
                "log_rotation_age = 1d",
                "log_rotation_size = 10MB",
                "log_truncate_on_rotation = on",
                "");
        Files.writeString(managed, body, StandardCharsets.UTF_8);

        if (!Files.exists(local)) {
            Files.writeString(local, String.join(System.lineSeparator(),
                    "# Operator overrides. OSCAR never rewrites this file.",
                    "# Settings here win over oscar.conf.",
                    ""), StandardCharsets.UTF_8);
        }

        String includes = String.join(System.lineSeparator(),
                "",
                "# --- added by OSCAR ---",
                "include_if_exists = 'oscar.conf'",
                "include_if_exists = 'oscar.local.conf'",
                "");
        String conf = Files.readString(pgConf, StandardCharsets.UTF_8);
        if (!conf.contains("include_if_exists = 'oscar.conf'")) {
            Files.writeString(pgConf, conf + includes, StandardCharsets.UTF_8);
        }

        writeHba();
        System.out.println("Wrote managed configuration (shared_buffers=" + sharedBuffersMb
                + "MB of " + ramMb + "MB detected).");
    }

    /** Loopback only. The database is an implementation detail of the node. */
    private void writeHba() throws IOException {
        String local = OscarPaths.isWindows()
                ? "# local: Unix-socket authentication does not exist on Windows"
                : "local   all   all                  trust";
        String hba = String.join(System.lineSeparator(),
                "# Managed by OSCAR. The embedded database accepts loopback connections only.",
                local,
                "host    all   all   127.0.0.1/32   scram-sha-256",
                "host    all   all   ::1/128        scram-sha-256",
                "");
        Files.writeString(paths.pgData().resolve("pg_hba.conf"), hba, StandardCharsets.UTF_8);
    }

    private static void restrictToOwner(Path path) {
        try {
            java.util.Set<java.nio.file.attribute.PosixFilePermission> perms =
                    Files.isDirectory(path)
                            ? java.nio.file.attribute.PosixFilePermissions.fromString("rwx------")
                            : java.nio.file.attribute.PosixFilePermissions.fromString("rw-------");
            Files.setPosixFilePermissions(path, perms);
        } catch (Exception ignored) {
            // Non-POSIX filesystem; the installer handles ACLs on Windows.
        }
    }

    // -------------------------------------------------------------- readiness

    /** Blocks until the server accepts a real connection, or the timeout expires. */
    boolean waitUntilReady(int timeoutSeconds) {
        long deadline = System.nanoTime() + timeoutSeconds * 1_000_000_000L;
        String lastError = "no attempt made";
        int attempt = 0;
        while (System.nanoTime() < deadline) {
            attempt++;
            try (Connection c = connect("postgres")) {
                try (Statement s = c.createStatement()) {
                    s.execute("SELECT 1");
                }
                System.out.println("Database ready after " + attempt + " attempt(s).");
                return true;
            } catch (SQLException e) {
                lastError = e.getMessage();
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return false;
                }
            }
        }
        System.err.println("Database did not become ready within " + timeoutSeconds
                + "s. Last error: " + lastError);
        return false;
    }

    Connection connect(String database) throws SQLException {
        Properties props = new Properties();
        props.setProperty("user", settings.dbUser());
        props.setProperty("password", settings.dbPassword());
        props.setProperty("connectTimeout", "5");
        String url = "jdbc:postgresql://" + settings.dbHost() + ":" + settings.dbPort() + "/" + database;
        return DriverManager.getConnection(url, props);
    }

    // ------------------------------------------------------------- extensions

    /** Creates the application database and its extensions. Idempotent. */
    void ensureDatabaseAndExtensions() throws SQLException {
        try (Connection admin = connect("postgres")) {
            if (!databaseExists(admin, settings.dbName())) {
                System.out.println("Creating database " + settings.dbName());
                try (Statement s = admin.createStatement()) {
                    // CREATE DATABASE cannot run inside a transaction block.
                    s.executeUpdate("CREATE DATABASE \"" + settings.dbName() + "\"");
                }
            }
        }

        try (Connection db = connect(settings.dbName()); Statement s = db.createStatement()) {
            List<String> created = new ArrayList<>();
            for (String ext : REQUIRED_EXTENSIONS) {
                s.executeUpdate("CREATE EXTENSION IF NOT EXISTS \"" + ext + "\"");
                created.add(ext);
            }
            System.out.println("Extensions present: " + String.join(", ", created));
        }
    }

    private boolean databaseExists(Connection c, String name) throws SQLException {
        try (var ps = c.prepareStatement("SELECT 1 FROM pg_database WHERE datname = ?")) {
            ps.setString(1, name);
            try (var rs = ps.executeQuery()) {
                return rs.next();
            }
        }
    }

    // ------------------------------------------------------------ server ctl

    void start() throws Exception {
        if (paths.pgSocketDir() != null)
            Files.createDirectories(paths.pgSocketDir());
        Proc.run(paths.pgExe("pg_ctl").toString(),
                "-D", paths.pgData().toString(),
                "-l", paths.data().resolve("postgres-startup.log").toString(),
                "-w", "-t", "300", "start");
    }

    void stop() throws Exception {
        Proc.run(paths.pgExe("pg_ctl").toString(),
                "-D", paths.pgData().toString(),
                "-m", "fast", "-w", "-t", "300", "stop");
    }
}
