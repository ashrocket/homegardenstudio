/** Worker bindings. Secrets have no defaults; a missing KEK_<current> makes key routes return 503. */
export interface Env extends Omit<WranglerBindings, "TEST_MIGRATIONS"> {
  /** Optional server-only secrets; generated configuration bindings contain no secret values. */
  ADMIN_TOKEN?: string;
  OPENAI_MANAGED_KEY?: string;
  [kek: `KEK_${number}`]: string | undefined;
}

/** Everything the Worker touches outside D1, injectable so tests need no network and no clock. */
export interface Deps {
  now: () => number;
  /** Resolved at call time so a test can stub it. */
  fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
  /** PEM roots that StoreKit certificate chains must end at. */
  trustedRoots: string[];
  uuid: () => string;
}

export type Provider = "openai" | "anthropic" | "custom";
export type BalanceEnvironment = "production" | "sandbox";

export interface Ctx {
  env: Env;
  deps: Deps;
  request: Request;
  url: URL;
  ip: string;
}

export interface AuthedCtx extends Ctx {
  accountId: string;
}

export const MICROS_PER_USD = 1_000_000;
export const LABEL_AI_CONCEPT = "AI concept: cloud rendering, not a measured plan";
