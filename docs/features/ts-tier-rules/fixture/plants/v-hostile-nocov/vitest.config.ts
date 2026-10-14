import { defineConfig } from "vitest/config";

// A hostile project config: every setting the recipe must not inherit.
export default defineConfig({
  cacheDir: "tests/acceptance/.vite-cache",
  test: {
    allowOnly: true,
    passWithNoTests: true,
    setupFiles: ["./canary.setup.ts"],
  },
});
