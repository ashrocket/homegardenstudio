import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";

const here = path.dirname(fileURLToPath(import.meta.url));

// Throwaway test-only secrets. Never real keys.
const TEST_KEK_1 = Buffer.alloc(32, 0x11).toString("base64");
const TEST_KEK_2 = Buffer.alloc(32, 0x22).toString("base64");

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(here, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            KEK_1: TEST_KEK_1,
            KEK_2: TEST_KEK_2,
            ADMIN_TOKEN: "test-admin-token-0123456789abcdef",
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
      fileParallelism: false,
      maxWorkers: 1,
      testTimeout: 30000,
    },
  };
});
