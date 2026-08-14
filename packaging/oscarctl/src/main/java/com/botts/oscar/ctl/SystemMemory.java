package com.botts.oscar.ctl;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Reports how much memory this machine actually has available.
 *
 * <p>Deliberately does not use {@code Runtime.maxMemory()} or a JVM RAM percentage.
 * When no cgroup limit is visible - the normal case inside an unprivileged LXC
 * container - the JVM falls back to a syscall that reports the *host's* physical
 * memory and bypasses the /proc/meminfo the container presents. Sizing anything from
 * that number hands out several times the memory the machine will actually allow.
 */
final class SystemMemory {

    private SystemMemory() {
    }

    static long totalMegabytes() {
        long fromMeminfo = readMeminfoMegabytes();
        long fromCgroup = readCgroupMegabytes();

        if (fromMeminfo <= 0 && fromCgroup <= 0)
            return 2048; // Conservative fallback.
        if (fromMeminfo <= 0)
            return fromCgroup;
        if (fromCgroup <= 0)
            return fromMeminfo;
        return Math.min(fromMeminfo, fromCgroup);
    }

    private static long readMeminfoMegabytes() {
        try {
            for (String line : Files.readAllLines(Path.of("/proc/meminfo"), StandardCharsets.UTF_8)) {
                if (line.startsWith("MemTotal:")) {
                    String[] parts = line.trim().split("\\s+");
                    return Long.parseLong(parts[1]) / 1024;
                }
            }
        } catch (Exception ignored) {
            // Not Linux, or /proc unavailable.
        }
        return -1;
    }

    private static long readCgroupMegabytes() {
        String[] candidates = {
                "/sys/fs/cgroup/memory.max",                    // cgroup v2
                "/sys/fs/cgroup/memory/memory.limit_in_bytes",  // cgroup v1
        };
        for (String candidate : candidates) {
            try {
                Path p = Path.of(candidate);
                if (!Files.isReadable(p))
                    continue;
                String value = Files.readString(p, StandardCharsets.UTF_8).trim();
                if (value.equals("max"))
                    continue;
                long bytes = Long.parseLong(value);
                // Kernels express "unlimited" as an enormous number rather than a flag.
                if (bytes > 0 && bytes < Long.MAX_VALUE / 2)
                    return bytes / (1024 * 1024);
            } catch (Exception ignored) {
                // Try the next candidate.
            }
        }
        return -1;
    }
}
