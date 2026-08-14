package com.botts.oscar.ctl;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.List;

/**
 * Mirrors the read-only trees from the program directory into the node's working
 * directory.
 *
 * <p>OSCAR reads {@code web}, {@code models}, {@code config}, {@code rules} and
 * {@code documentation} relative to its current working directory, and those paths
 * come from a mix of JVM flags and values inside config.json that the node rewrites
 * at runtime. Only the classpath and the logback file can be made absolute from
 * outside, so the remaining trees are copied next to the mutable state instead.
 *
 * <p>Copying rather than symlinking keeps this working on Windows, where creating a
 * symlink needs a privilege that is not granted by default and a junction would let
 * a runtime write escape into Program Files.
 */
final class WebSync {

    private static final List<String> MIRRORED =
            List.of("web", "models", "config", "rules", "documentation");

    private static final String MARKER = ".oscar-version";

    private final OscarPaths paths;

    WebSync(OscarPaths paths) {
        this.paths = paths;
    }

    void sync() throws IOException {
        String installed = readVersion(paths.home().resolve("VERSION"));
        Path markerFile = paths.nodeDir().resolve(MARKER);
        String current = Files.isReadable(markerFile)
                ? Files.readString(markerFile, StandardCharsets.UTF_8).trim()
                : null;

        if (installed != null && installed.equals(current)) {
            System.out.println("Static content already at version " + installed + "; nothing to do.");
            writeViewerConfig();
            return;
        }

        Files.createDirectories(paths.nodeDir());
        for (String name : MIRRORED) {
            Path from = paths.home().resolve(name);
            if (!Files.isDirectory(from))
                continue;
            Path to = paths.nodeDir().resolve(name);
            deleteRecursively(to);
            copyRecursively(from, to);
            System.out.println("Synced " + name + "/");
        }

        writeViewerConfig();

        if (installed != null) {
            Files.writeString(markerFile, installed, StandardCharsets.UTF_8);
        }
    }

    /**
     * Publishes the viewer's runtime endpoint configuration into the served web root.
     *
     * <p>Written on every sync because the web tree is replaced wholesale on upgrade,
     * which would otherwise discard it.
     */
    private void writeViewerConfig() throws IOException {
        Path source = paths.config().resolve("viewer-config.json");
        Path webRoot = paths.nodeDir().resolve("web");
        if (!Files.isDirectory(webRoot) || !Files.isReadable(source))
            return;
        Files.copy(source, webRoot.resolve("oscar-config.json"),
                StandardCopyOption.REPLACE_EXISTING);
        System.out.println("Published viewer configuration to web/oscar-config.json");
    }

    private static String readVersion(Path versionFile) throws IOException {
        if (!Files.isReadable(versionFile))
            return null;
        String v = Files.readString(versionFile, StandardCharsets.UTF_8).trim();
        return v.isBlank() ? null : v;
    }

    private static void copyRecursively(Path from, Path to) throws IOException {
        Files.walkFileTree(from, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs)
                    throws IOException {
                Files.createDirectories(to.resolve(from.relativize(dir).toString()));
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attrs)
                    throws IOException {
                Files.copy(file, to.resolve(from.relativize(file).toString()),
                        StandardCopyOption.REPLACE_EXISTING);
                return FileVisitResult.CONTINUE;
            }
        });
    }

    private static void deleteRecursively(Path path) throws IOException {
        if (!Files.exists(path))
            return;
        Files.walkFileTree(path, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attrs)
                    throws IOException {
                Files.delete(file);
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult postVisitDirectory(Path dir, IOException e) throws IOException {
                if (e != null)
                    throw e;
                Files.delete(dir);
                return FileVisitResult.CONTINUE;
            }
        });
    }
}
