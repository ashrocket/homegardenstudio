import { HttpError, json } from "./errors";
import type { AuthedCtx, Ctx } from "./types";
import { randomBytes, sha256Hex, toBase64Url } from "./util";

const SECRET_RE = /^hgs_[A-Za-z0-9_-]{43}$/;
const HOUR_MS = 60 * 60 * 1000;
export const ACCOUNT_CREATE_PER_IP_PER_HOUR = 5;
export const DELETION_RECEIPT_TTL_MS = 30 * 24 * HOUR_MS;

/**
 * Fixed-window counter kept in D1 (a Worker has no shared memory). Throws 429 once `limit` is exceeded.
 * Buckets hold a hash, never a raw IP or account id.
 */
export async function rateLimit(db: D1Database, bucket: string, limit: number, windowMs: number, now: number): Promise<void> {
  const windowStart = Math.floor(now / windowMs) * windowMs;
  const row = await db
    .prepare(
      `INSERT INTO rate_limits (bucket, window_start, count) VALUES (?1, ?2, 1)
       ON CONFLICT (bucket, window_start) DO UPDATE SET count = count + 1
       RETURNING count`,
    )
    .bind(bucket, windowStart)
    .first<{ count: number }>();
  if ((row?.count ?? 0) > limit) {
    const retryAfter = Math.max(1, Math.ceil((windowStart + windowMs - now) / 1000));
    throw new HttpError(429, "RATE_LIMITED", "Too many requests. Try again later.", {}, { "retry-after": String(retryAfter) });
  }
  // Opportunistic cleanup of finished windows.
  if (Math.random() < 0.02) {
    await db.prepare("DELETE FROM rate_limits WHERE window_start < ?1").bind(now - 2 * Math.max(windowMs, 24 * HOUR_MS)).run();
  }
}

export async function createAccount(ctx: Ctx): Promise<Response> {
  const { env, deps } = ctx;
  const now = deps.now();
  await rateLimit(env.DB, `acct:${await sha256Hex(`hgs-ip|${ctx.ip}`)}`, ACCOUNT_CREATE_PER_IP_PER_HOUR, HOUR_MS, now);
  const accountId = deps.uuid();
  const secret = `hgs_${toBase64Url(randomBytes(32))}`;
  const hash = await sha256Hex(secret);
  await env.DB.prepare("INSERT INTO accounts (id, secret_hash, created_at) VALUES (?1, ?2, ?3)").bind(accountId, hash, now).run();
  return json({ account_id: accountId, secret }, 201);
}

function unauthorized(): HttpError {
  return new HttpError(401, "UNAUTHORIZED", "Missing or invalid account credentials.", {}, { "www-authenticate": "Bearer" });
}

/** Resolves `Authorization: Bearer hgs_...` to an account. Only SHA-256(secret) is stored. */
export async function authenticate(ctx: Ctx): Promise<AuthedCtx> {
  const header = ctx.request.headers.get("authorization") ?? "";
  const m = /^Bearer (\S+)$/.exec(header);
  const secret = m?.[1];
  if (!secret || !SECRET_RE.test(secret)) throw unauthorized();
  const hash = await sha256Hex(secret);
  let row = await ctx.env.DB.prepare("SELECT id FROM accounts WHERE secret_hash = ?1 AND deleted_at IS NULL")
    .bind(hash)
    .first<{ id: string }>();
  // A deletion receipt is valid only for repeating the exact destructive endpoint.
  // It never restores reads, purchases, custody or generation after revocation.
  if (!row && ctx.request.method === "DELETE" && ctx.url.pathname === "/v1/me") {
    row = await ctx.env.DB.prepare(`SELECT r.account_id AS id FROM account_deletion_receipts r
      JOIN accounts a ON a.id=r.account_id WHERE r.secret_hash=?1 AND a.deleted_at IS NOT NULL
      AND (r.completed_at IS NULL OR r.completed_at>?2)`).bind(hash, ctx.deps.now() - DELETION_RECEIPT_TTL_MS).first<{id:string}>();
  }
  if (!row) throw unauthorized();
  return { ...ctx, accountId: row.id };
}
