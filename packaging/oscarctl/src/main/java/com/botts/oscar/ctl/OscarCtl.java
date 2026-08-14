package com.botts.oscar.ctl;

import java.nio.file.Files;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;

/**
 * Entry point for OSCAR's install-time and service-time operations.
 *
 * <p>Exists as a Java tool rather than a pair of shell and batch scripts because every
 * one of these steps has to behave identically on Linux and Windows, and because it
 * already has a JDBC driver on the classpath - which means none of the database work
 * needs a {@code psql} binary on PATH.
 *
 * <p>Ships into the node's {@code lib/} and is launched with {@code -cp "lib/*"}, so it
 * reuses the PostgreSQL driver and security-utils already there and needs no shading.
 */
public final class OscarCtl {

    public static void main(String[] args) {
        if (args.length == 0) {
            usage();
            System.exit(2);
        }

        String command = args[0];
        try {
            OscarPaths paths = OscarPaths.fromEnvironment();
            Settings settings = new Settings(paths);
            Postgres pg = new Postgres(paths, settings);

            switch (command) {
                case "init-db" -> pg.initCluster();
                case "start-db" -> pg.start();
                case "stop-db" -> pg.stop();
                case "wait-db" -> {
                    int timeout = intOption(args, "--timeout", 180);
                    if (!pg.waitUntilReady(timeout))
                        System.exit(1);
                }
                case "ensure-extensions" -> pg.ensureDatabaseAndExtensions();
                case "render-config" -> new ConfigRenderer(paths, settings).render();
                case "sync-web" -> new WebSync(paths).sync();
                case "doctor" -> System.exit(doctor(paths, settings, pg) ? 0 : 1);
                case "paths" -> System.out.println(paths);
                case "help", "--help", "-h" -> usage();
                default -> {
                    System.err.println("Unknown command: " + command);
                    usage();
                    System.exit(2);
                }
            }
        } catch (Exception e) {
            System.err.println("oscarctl " + command + " failed: " + e.getMessage());
            if (System.getenv("OSCAR_CTL_DEBUG") != null)
                e.printStackTrace();
            System.exit(1);
        }
    }

    /**
     * Field-engineer health check. Reports everything it finds rather than stopping at
     * the first problem, because the useful output is the whole picture.
     */
    private static boolean doctor(OscarPaths paths, Settings settings, Postgres pg) {
        boolean ok = true;
        System.out.println("OSCAR installation check");
        System.out.println("  " + paths);
        System.out.println();

        ok &= report("program directory", Files.isDirectory(paths.home()), paths.home().toString());
        ok &= report("bundled postgres", Files.isExecutable(paths.pgBin().resolve("postgres")),
                paths.pgBin().toString());
        ok &= report("data directory", Files.isDirectory(paths.data()), paths.data().toString());
        ok &= report("cluster initialised", pg.clusterExists(), paths.pgData().toString());
        ok &= report("node config present",
                Files.isRegularFile(paths.nodeDir().resolve("config.json")),
                paths.nodeDir().resolve("config.json").toString());

        boolean reachable = pg.waitUntilReady(5);
        ok &= report("database reachable", reachable,
                settings.dbHost() + ":" + settings.dbPort());

        if (reachable) {
            try (Connection c = pg.connect(settings.dbName()); Statement s = c.createStatement()) {
                try (ResultSet rs = s.executeQuery(
                        "SELECT extname FROM pg_extension ORDER BY extname")) {
                    StringBuilder found = new StringBuilder();
                    while (rs.next()) {
                        if (found.length() > 0)
                            found.append(", ");
                        found.append(rs.getString(1));
                    }
                    boolean allPresent = Postgres.REQUIRED_EXTENSIONS.stream()
                            .allMatch(e -> found.toString().contains(e));
                    ok &= report("extensions installed", allPresent, found.toString());
                }
                try (ResultSet rs = s.executeQuery("SELECT postgis_version()")) {
                    if (rs.next())
                        ok &= report("postgis responding", true, rs.getString(1));
                }
            } catch (Exception e) {
                ok &= report("database queries", false, e.getMessage());
            }
        }

        System.out.println();
        System.out.println(ok ? "All checks passed." : "One or more checks FAILED.");
        return ok;
    }

    private static boolean report(String label, boolean pass, String detail) {
        System.out.printf("  [%s] %-22s %s%n", pass ? "ok" : "FAIL", label, detail);
        return pass;
    }

    private static int intOption(String[] args, String name, int fallback) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals(name))
                return Integer.parseInt(args[i + 1]);
            if (args[i].startsWith(name + "="))
                return Integer.parseInt(args[i].substring(name.length() + 1));
        }
        for (String a : args) {
            if (a.startsWith(name + "="))
                return Integer.parseInt(a.substring(name.length() + 1));
        }
        return fallback;
    }

    private static void usage() {
        System.out.println("""
                Usage: oscarctl <command> [options]

                  init-db              Create the PostgreSQL cluster if absent and write
                                       OSCAR's managed configuration. Idempotent. Refuses to
                                       run against a cluster from a different major version.
                  start-db             Start the embedded server and wait for it.
                  stop-db              Stop the embedded server (fast shutdown).
                  wait-db --timeout N  Block until the database accepts connections (default 180s).
                  ensure-extensions    Create the application database and its extensions.
                  render-config        Write config.json on first install only. Never
                                       overwrites an existing one.
                  sync-web             Mirror web/, models/, config/, rules/ and documentation/
                                       into the node working directory.
                  doctor               Report the health of this installation.
                  paths                Print the resolved program, config and data roots.

                Environment:
                  OSCAR_HOME           Program directory (default: parent of this jar's lib/)
                  OSCAR_CONFIG         Configuration directory
                  OSCAR_DATA           Data directory (pgdata/, node/)
                  OSCAR_ADMIN_PASSWORD Initial admin password for render-config
                """);
    }
}
