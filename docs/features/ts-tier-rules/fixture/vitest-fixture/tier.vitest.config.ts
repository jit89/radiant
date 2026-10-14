import { defineConfig } from "vitest/config";

// The Tier 1 recipe config: never imports or extends the project's config.
export default defineConfig({
  test: { include: ["tests/acceptance/**/*.test.ts"], allowOnly: false },
});
