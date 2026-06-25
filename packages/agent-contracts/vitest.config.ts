import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    coverage: {
      provider: "v8",
      // The generated types are type-only (no runtime); the barrel only re-exports.
      // 100% is enforced on the hand-written client logic.
      include: ["src/client.ts"],
      thresholds: { lines: 100, branches: 100, functions: 100, statements: 100 },
    },
  },
});
