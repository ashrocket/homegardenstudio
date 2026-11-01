import type { D1Migration } from "@cloudflare/vitest-pool-workers";

declare global {
  namespace Cloudflare {
    interface Env {
      /** Disposable local-test migration fixture, never a deployed binding. */
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
