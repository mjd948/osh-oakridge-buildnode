package com.botts.oscar.ctl;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.Arrays;

/** Runs a bundled binary, streaming its output, and fails loudly on a non-zero exit. */
final class Proc {

    private Proc() {
    }

    static void run(String... command) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(command);
        pb.redirectErrorStream(true);
        Process p = pb.start();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
            String line;
            while ((line = r.readLine()) != null) {
                System.out.println("  " + line);
            }
        }
        int exit = p.waitFor();
        if (exit != 0) {
            throw new IllegalStateException(
                    "Command failed with exit " + exit + ": " + String.join(" ", Arrays.asList(command)));
        }
    }
}
