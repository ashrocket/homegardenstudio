import type { BalanceEnvironment } from "./types";

/**
 * Atomicity model. `D1Database.batch()` runs its statements in one transaction and rolls the whole thing back
 * when any statement raises. A statement that merely matches zero rows does NOT raise, so every guard here is
 * written to raise: a CHECK constraint (balances >= 0, monthly cap, window remainder >= 0, sponsor budget >= 0),
 * a UNIQUE constraint (idempotency keys, one job per quote, one transaction row per transactionId), or
 * `assertSql`. After a failed batch the caller re-reads state to decide which error to return.
 */

/** abs(INT64_MIN) is an "integer overflow" error in SQLite: a portable way to abort a batch from SQL. */
export function assertSql(db: D1Database, condition: string, ...binds: unknown[]): D1PreparedStatement {
  return db
    .prepare(`SELECT abs(CASE WHEN (${condition}) THEN 0 ELSE -9223372036854775808 END)`)
    .bind(...binds);
}

export interface Balances {
  production: number;
  sandbox: number;
}

export async function getBalances(db: D1Database, accountId: string): Promise<Balances> {
  const { results } = await db
    .prepare("SELECT b.environment, MAX(0, b.micros - COALESCE((SELECT SUM(t.shortfall_micros) FROM transactions t WHERE t.account_id=b.account_id AND t.balance_environment=b.environment AND t.revoked_at IS NOT NULL),0)) AS micros FROM balances b WHERE b.account_id = ?1")
    .bind(accountId)
    .all<{ environment: BalanceEnvironment; micros: number }>();
  const out: Balances = { production: 0, sandbox: 0 };
  for (const r of results) out[r.environment] = r.micros;
  return out;
}

/** Adds `delta` (may be negative) to a balance. A negative result violates balances_nonnegative and aborts the batch. */
export function balanceDelta(db: D1Database, accountId: string, env: BalanceEnvironment, delta: number, now: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO balances (account_id, environment, micros, updated_at) VALUES (?1, ?2, COALESCE((SELECT micros FROM balances WHERE account_id = ?1 AND environment = ?2), 0) + ?3, ?4)
       ON CONFLICT (account_id, environment) DO UPDATE SET micros = excluded.micros, updated_at = excluded.updated_at`,
    )
    .bind(accountId, env, delta, now);
}

export type LedgerKind = "grant" | "debit" | "job_refund" | "clawback" | "clawback_reversal";

export function ledgerInsert(
  db: D1Database,
  e: {
    accountId: string;
    source: "balance" | "sponsor_window";
    environment: BalanceEnvironment | null;
    kind: LedgerKind;
    amount: number;
    key: string;
    ref: string;
    now: number;
  },
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO ledger (account_id, source, environment, kind, amount_micros, idempotency_key, ref, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
    .bind(e.accountId, e.source, e.environment, e.kind, e.amount, e.key, e.ref, e.now);
}

/** Ledger credit plus balance increment, to be placed in one batch. `grant:<transactionId>` makes it once-only. */
export function grantStatements(
  db: D1Database,
  e: { accountId: string; environment: BalanceEnvironment; amount: number; key: string; ref: string; now: number },
): D1PreparedStatement[] {
  return [
    ledgerInsert(db, { ...e, source: "balance", kind: "grant" }),
    balanceDelta(db, e.accountId, e.environment, e.amount, e.now),
  ];
}

/** Calendar month in UTC, `YYYY-MM`. */
export function monthKey(now: number): string {
  return new Date(now).toISOString().slice(0, 7);
}

export async function monthSpent(db: D1Database, accountId: string, now: number): Promise<number> {
  const r = await db
    .prepare("SELECT spent_micros FROM month_spend WHERE account_id = ?1 AND month_key = ?2")
    .bind(accountId, monthKey(now))
    .first<{ spent_micros: number }>();
  return r?.spent_micros ?? 0;
}

/** Counts a balance debit toward the cap. The cap is re-read from accounts so the CHECK sees the current value. */
export function monthSpendAdd(db: D1Database, accountId: string, key: string, amount: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO month_spend (account_id, month_key, spent_micros, cap_micros)
       VALUES (?1, ?2, ?3, (SELECT monthly_cap_micros FROM accounts WHERE id = ?1))
       ON CONFLICT (account_id, month_key) DO UPDATE SET spent_micros = spent_micros + excluded.spent_micros, cap_micros = excluded.cap_micros`,
    )
    .bind(accountId, key, amount);
}

export function monthSpendRelease(db: D1Database, accountId: string, key: string, amount: number): D1PreparedStatement {
  return db
    .prepare("UPDATE month_spend SET spent_micros = MAX(spent_micros - ?3, 0) WHERE account_id = ?1 AND month_key = ?2")
    .bind(accountId, key, amount);
}

export interface Entitlements {
  ios: boolean;
  macos: boolean;
  bundle: boolean;
}

export const PRODUCT_GRANTS: Record<string, Array<keyof Entitlements>> = {
  "unlock.ios": ["ios"],
  "unlock.mac": ["macos"],
  "unlock.bundle": ["ios", "macos", "bundle"],
  "upgrade.ios_to_bundle": ["ios", "macos", "bundle"],
  "upgrade.mac_to_bundle": ["ios", "macos", "bundle"],
};

/** Derived from unrevoked, granted transactions every time. Never stored as booleans. */
export async function getEntitlements(db: D1Database, accountId: string, environment: BalanceEnvironment = "production"): Promise<Entitlements> {
  const { results } = await db
    .prepare(`SELECT DISTINCT t.product_id FROM transactions t WHERE t.account_id = ?1 AND t.balance_environment = ?2 AND t.status = 'granted' AND t.revoked_at IS NULL
      AND (t.product_id NOT IN ('upgrade.ios_to_bundle', 'upgrade.mac_to_bundle') OR EXISTS
      (SELECT 1 FROM transactions p WHERE p.account_id = t.account_id AND p.store_environment = t.store_environment
       AND p.status = 'granted' AND p.revoked_at IS NULL AND p.product_id = CASE t.product_id WHEN 'upgrade.ios_to_bundle' THEN 'unlock.ios' ELSE 'unlock.mac' END))`)
    .bind(accountId, environment)
    .all<{ product_id: string }>();
  const out: Entitlements = { ios: false, macos: false, bundle: false };
  for (const r of results) for (const g of PRODUCT_GRANTS[r.product_id] ?? []) out[g] = true;
  return out;
}
