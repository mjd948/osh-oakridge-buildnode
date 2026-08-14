package com.botts.oscar.ctl;

import com.botts.impl.security.PBKDF2Credential;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * Produces the node's {@code config.json} on first install only.
 *
 * <p>This replaces {@code set-initial-admin-password.sh}, which rewrote config.json in
 * place on every single launch. That was survivable only because the placeholder
 * disappeared after the first substitution. It is not survivable across an upgrade:
 * OSH rewrites config.json itself at runtime as modules are added through the admin UI
 * - on the reference install it had grown from the 7.7 KB shipped template to 30 KB -
 * so an installer that touches an existing config.json destroys the operator's system.
 *
 * <p>The rule enforced here is absolute: if config.json exists, do nothing.
 */
final class ConfigRenderer {

    private static final String PLACEHOLDER = "__INITIAL_ADMIN_PASSWORD__";

    private final OscarPaths paths;
    private final Settings settings;

    ConfigRenderer(OscarPaths paths, Settings settings) {
        this.paths = paths;
        this.settings = settings;
    }

    void render() throws Exception {
        Path target = paths.nodeDir().resolve("config.json");

        if (Files.exists(target)) {
            System.out.println("Existing configuration preserved: " + target);
            System.out.println("(config.json is never rewritten once it exists.)");
            return;
        }

        Path template = firstExisting(
                paths.config().resolve("config.template.json"),
                paths.home().resolve("config.template.json"),
                paths.home().resolve("config.json"));

        if (template == null) {
            throw new IllegalStateException("No config template found under "
                    + paths.config() + " or " + paths.home());
        }

        String body = Files.readString(template, StandardCharsets.UTF_8);

        if (body.contains(PLACEHOLDER)) {
            String encoded = PBKDF2Credential
                    .fromPassword(settings.initialAdminPassword(), PBKDF2Credential.DEFAULT_STRENGTH)
                    .toString();
            body = body.replace(PLACEHOLDER, encoded);
            System.out.println("Applied initial admin password (hashed).");
        } else {
            System.out.println("Template carries no password placeholder; copying as-is.");
        }

        Files.createDirectories(paths.nodeDir());
        Path tmp = target.resolveSibling("config.json.tmp");
        Files.writeString(tmp, body, StandardCharsets.UTF_8);
        restrictToOwner(tmp);
        Files.move(tmp, target, StandardCopyOption.ATOMIC_MOVE);

        System.out.println("Wrote " + target);
    }

    private static Path firstExisting(Path... candidates) {
        for (Path p : candidates) {
            if (Files.isRegularFile(p))
                return p;
        }
        return null;
    }

    private static void restrictToOwner(Path path) {
        try {
            Files.setPosixFilePermissions(path,
                    java.nio.file.attribute.PosixFilePermissions.fromString("rw-------"));
        } catch (Exception ignored) {
            // Non-POSIX filesystem.
        }
    }
}
