import "reflect-metadata";
import { BasicConstraintsExtension, X509Certificate } from "@peculiar/x509";
import { HttpError, json } from "./errors";
import { assertSql, balanceDelta, getBalances, getEntitlements, grantStatements, ledgerInsert } from "./ledger";
import type { AuthedCtx, BalanceEnvironment, Ctx, Env } from "./types";
import { fromBase64, fromBase64Url, isGuardFailure, isInt, isUuid } from "./util";

export const PRODUCT_PREFIX = "com.ashleyraiteri.homegardenstudio.";

/** Apple's marker extensions: the leaf carries ...6.11.1 and the intermediate ...6.2.1. */
const OID_LEAF = "1.2.840.113635.100.6.11.1";
const OID_INTERMEDIATE = "1.2.840.113635.100.6.2.1";

interface ProductDef {
  credit: number;
  requires?: string;
  /** Name of an env var that must equal "true" for the product to be accepted. */
  enabledBy?: "ENABLE_MAC_UPGRADE";
}

const PRODUCTS = new Map<string, ProductDef>([
  ["unlock.ios", { credit: 2_000_000 }],
  ["unlock.mac", { credit: 2_000_000 }],
  ["unlock.bundle", { credit: 5_000_000 }],
  ["upgrade.ios_to_bundle", { credit: 5_000_000, requires: "unlock.ios" }],
  ["upgrade.mac_to_bundle", { credit: 5_000_000, requires: "unlock.mac", enabledBy: "ENABLE_MAC_UPGRADE" }],
]);

const invalidJws = (message: string) => new HttpError(400, "INVALID_JWS", message);
const untrusted = (message: string) => new HttpError(400, "UNTRUSTED_CHAIN", message);
const badSignature = () => new HttpError(400, "BAD_SIGNATURE", "The signature does not verify.");

const rootCache = new Map<string, X509Certificate>();
function loadRoot(pem: string): X509Certificate {
  let c = rootCache.get(pem);
  if (!c) {
    c = new X509Certificate(pem);
    rootCache.set(pem, c);
  }
  return c;
}

const sameBytes = (a: ArrayBuffer, b: ArrayBuffer): boolean => {
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  if (x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
};

const within = (c: X509Certificate, at: Date): boolean => c.notBefore.getTime() <= at.getTime() && at.getTime() <= c.notAfter.getTime();

function parseJsonPart(part: string, what: string): Record<string, unknown> {
  try {
    const v: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(fromBase64Url(part)));
    if (v === null || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object");
    return v as Record<string, unknown>;
  } catch {
    throw invalidJws(`The JWS ${what} is malformed.`);
  }
}

/**
 * Verifies an App Store JWS (signed transaction or server notification) and returns its payload.
 * ES256 only. The x5c chain must be leaf -> intermediate -> a trusted root, every certificate valid at `signedDate`,
 * with Apple's marker OIDs on the leaf and intermediate. The signature is then checked with the leaf key.
 */
export async function verifyAppleJws(jws: unknown, trustedRootsPem: string[]): Promise<Record<string, unknown>> {
  if (typeof jws !== "string" || jws.length < 10 || jws.length > 30_000) throw invalidJws("The JWS is missing or too large.");
  const parts = jws.split(".");
  if (parts.length !== 3 || parts.some((p) => p.length === 0)) throw invalidJws("The JWS must have three parts.");
  const [h, p, s] = parts as [string, string, string];
  const header = parseJsonPart(h, "header");
  if (header.alg !== "ES256") throw invalidJws("Only ES256 is accepted.");
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2 || x5c.length > 3 || x5c.some((c) => typeof c !== "string")) {
    throw invalidJws("The JWS header needs an x5c chain of two or three certificates.");
  }
  const payload = parseJsonPart(p, "payload");
  const signedDate = payload.signedDate;
  if (!isInt(signedDate) || signedDate <= 0) throw invalidJws("The JWS payload has no signedDate.");
  const at = new Date(signedDate);

  let certs: X509Certificate[];
  try {
    certs = (x5c as string[]).map((c) => new X509Certificate(fromBase64(c)));
  } catch {
    throw invalidJws("A certificate in x5c could not be parsed.");
  }
  const [leaf, intermediate, presentedRoot] = certs as [X509Certificate, X509Certificate, X509Certificate | undefined];

  if (!within(leaf, at) || !within(intermediate, at)) throw untrusted("A certificate in the chain is not valid at signedDate.");
  if (!leaf.getExtension(OID_LEAF)) throw untrusted("The leaf certificate lacks Apple's receipt-signing marker.");
  if (!intermediate.getExtension(OID_INTERMEDIATE)) throw untrusted("The intermediate certificate lacks Apple's marker.");
  if (intermediate.getExtension(BasicConstraintsExtension)?.ca !== true) throw untrusted("The intermediate is not a CA.");
  if (leaf.getExtension(BasicConstraintsExtension)?.ca === true) throw untrusted("The leaf must not be a CA.");

  const roots = trustedRootsPem.map(loadRoot);
  const root = roots.find((r) => intermediate.issuer === r.subject);
  if (!root) throw untrusted("The chain does not end at a trusted root.");
  if (!within(root, at)) throw untrusted("The trusted root is not valid at signedDate.");
  if (presentedRoot && !roots.some((r) => sameBytes(r.rawData, presentedRoot.rawData))) {
    throw untrusted("The chain presents a root that is not trusted.");
  }
  if (!(await intermediate.verify({ publicKey: root.publicKey, signatureOnly: true }))) {
    throw untrusted("The intermediate is not signed by the trusted root.");
  }
  if (leaf.issuer !== intermediate.subject || !(await leaf.verify({ publicKey: intermediate.publicKey, signatureOnly: true }))) {
    throw untrusted("The leaf is not signed by the intermediate.");
  }

  let sig: Uint8Array;
  try {
    sig = fromBase64Url(s);
  } catch {
    throw badSignature();
  }
  if (sig.length !== 64) throw badSignature(); // ES256 signatures are raw r||s
  let ok = false;
  try {
    const key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
    ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, new TextEncoder().encode(`${h}.${p}`));
  } catch {
    ok = false;
  }
  if (!ok) throw badSignature();
  return payload;
}

export type StoreEnvironment = "Production" | "Sandbox";
export interface TxClaims {
  transactionId: string; originalTransactionId: string; bundleId: string; productId: string;
  environment: StoreEnvironment; appAccountToken: string; revocationDate: number | null;
  purchaseDate: number | null; signedDate: number;
}
export function entitlementEnvironment(env: Env): BalanceEnvironment {
  return env.ENTITLEMENT_ENVIRONMENT === "sandbox" ? "sandbox" : "production";
}
export function creditProducts(env: Env): Record<string, number> {
  try {
    const data: unknown = JSON.parse(env.CREDIT_PRODUCTS || "{}");
    if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error();
    for (const [id, credit] of Object.entries(data)) {
      if (!id.startsWith(PRODUCT_PREFIX + "credit.") || !/^[\w.]{1,180}$/.test(id) || !isInt(credit) || credit <= 0 || credit > 500_000_000) throw new Error();
    }
    return data as Record<string, number>;
  } catch { throw new HttpError(503, "PRODUCT_CONFIGURATION_INVALID", "Credit products are unavailable."); }
}
function product(env: Env, id: string): { short: string; def: ProductDef } {
  const short = id.startsWith(PRODUCT_PREFIX) ? id.slice(PRODUCT_PREFIX.length) : "";
  const pack = creditProducts(env)[id];
  const def = PRODUCTS.get(short) ?? (pack ? { credit: pack } : undefined);
  if (!def) throw new HttpError(400, "UNKNOWN_PRODUCT", "That product is not configured for this app.");
  if (def.enabledBy && env[def.enabledBy] !== "true") throw new HttpError(400, "PRODUCT_DISABLED", "That product is unavailable.");
  return { short, def };
}
function parseClaims(p: Record<string, unknown>, ctx: Ctx): TxClaims {
  if (p.bundleId !== ctx.env.BUNDLE_ID) throw new HttpError(400, "WRONG_BUNDLE", "The transaction belongs to a different app.");
  if (p.environment !== "Production" && !(p.environment === "Sandbox" && ctx.env.ACCEPT_SANDBOX === "true")) {
    throw new HttpError(400, "ENVIRONMENT_NOT_ACCEPTED", "This receipt environment is not accepted. Local Xcode receipts are never accepted.");
  }
  for (const key of ["transactionId", "originalTransactionId"]) {
    if (typeof p[key] !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(p[key] as string)) throw invalidJws("Invalid transaction identifier.");
  }
  if (typeof p.productId !== "string" || typeof p.appAccountToken !== "string" || !/^[0-9a-f-]{36}$/i.test(p.appAccountToken)) {
    throw new HttpError(403, "ACCOUNT_TOKEN_REQUIRED", "A verified purchase must carry this account's appAccountToken.");
  }
  if (!isInt(p.signedDate) || p.signedDate <= 0 || p.signedDate > ctx.deps.now() + 300_000) throw invalidJws("Invalid signedDate.");
  if (p.revocationDate != null && (!isInt(p.revocationDate) || p.revocationDate <= 0)) throw invalidJws("Invalid revocationDate.");
  if (p.purchaseDate != null && (!isInt(p.purchaseDate) || p.purchaseDate <= 0)) throw invalidJws("Invalid purchaseDate.");
  return { transactionId: p.transactionId as string, originalTransactionId: p.originalTransactionId as string,
    bundleId: p.bundleId as string, productId: p.productId, environment: p.environment as StoreEnvironment,
    appAccountToken: p.appAccountToken.toLowerCase(), signedDate: p.signedDate,
    revocationDate: p.revocationDate as number ?? null, purchaseDate: p.purchaseDate as number ?? null };
}
interface TxRow {
  transaction_id: string; original_transaction_id: string; account_id: string; product_id: string; store_environment: StoreEnvironment;
  balance_environment: BalanceEnvironment; status: string; revoked_at: number | null;
  credit_granted_micros: number; clawed_back_micros: number;
}
interface StateRow {
  signed_date: number; revoked_at: number | null; original_transaction_id: string;
  product_id: string; store_environment: StoreEnvironment; account_token: string;
}
const state = (db: D1Database, tid: string) => db.prepare("SELECT * FROM storekit_states WHERE transaction_id=?").bind(tid).first<StateRow>();

/** Verified claims only. Exported for deterministic financial-state tests; no HTTP route accepts unsigned claims. */
export async function reconcileVerified(ctx: Ctx, c: TxClaims, accountId: string | null, eventId?: string): Promise<void> {
  const { env, deps } = ctx;
  const db = env.DB, now = deps.now();
  const short = c.productId.startsWith(PRODUCT_PREFIX) ? c.productId.slice(PRODUCT_PREFIX.length) : "";
  if (!/^[A-Za-z0-9_.-]{1,100}$/.test(short)) throw new HttpError(400,"UNKNOWN_PRODUCT","The signed product identifier is invalid.");
  const registered = await db.prepare("SELECT transaction_id FROM transactions WHERE transaction_id=?").bind(c.transactionId).first();
  // Disabling a product must never block refunds/restores of an already registered transaction.
  if (accountId && !registered) product(env,c.productId);
  if (accountId && c.appAccountToken !== accountId.toLowerCase()) throw new HttpError(403, "ACCOUNT_MISMATCH", "This purchase belongs to a different account.");
  const binding = await db.prepare("SELECT account_id FROM transaction_bindings WHERE original_transaction_id=?").bind(c.originalTransactionId).first<{account_id:string}>();
  if (binding && binding.account_id.toLowerCase() !== c.appAccountToken) throw new HttpError(409,"BOUND_TO_OTHER_ACCOUNT","This purchase is linked to another account.");
  for (let attempt = 0; attempt < 5; attempt++) {
    const old = await state(db, c.transactionId);
    if (old && (old.account_token !== c.appAccountToken || old.product_id !== short || old.store_environment !== c.environment || old.original_transaction_id !== c.originalTransactionId)) {
      throw new HttpError(409, "TRANSACTION_IDENTITY_CONFLICT", "Verified transaction identity changed; reconciliation is required.");
    }
    if (old && old.signed_date === c.signedDate && old.revoked_at !== c.revocationDate) {
      throw new HttpError(409, "AMBIGUOUS_PURCHASE_STATE", "Conflicting signed states require a fresh verified transaction.");
    }
    const effective = old && old.signed_date >= c.signedDate ? old : {
      signed_date: c.signedDate, revoked_at: c.revocationDate, original_transaction_id: c.originalTransactionId,
      product_id: short, store_environment: c.environment, account_token: c.appAccountToken,
    };
    const row = await db.prepare("SELECT * FROM transactions WHERE transaction_id=?").bind(c.transactionId).first<TxRow>();
    if (row && row.account_id.toLowerCase() !== c.appAccountToken) throw new HttpError(409, "BOUND_TO_OTHER_ACCOUNT", "This purchase is linked to another account.");
    if (row && (row.product_id !== short || row.store_environment !== c.environment || row.original_transaction_id !== c.originalTransactionId)) {
      throw new HttpError(409, "TRANSACTION_IDENTITY_CONFLICT", "The registered transaction identity does not match the signed evidence.");
    }
    const stmts: D1PreparedStatement[] = [assertSql(db, old ? "(SELECT signed_date FROM storekit_states WHERE transaction_id=?1)=?2" : "NOT EXISTS(SELECT 1 FROM storekit_states WHERE transaction_id=?1)", ...(old ? [c.transactionId, old.signed_date] : [c.transactionId]))];
    // Pending grant release and initial registration can race this snapshot without changing signedDate.
    // Guard every financial field consumed by the branch before mutating signed state; a loser re-reads and retries.
    stmts.push(row
      ? assertSql(db, "EXISTS(SELECT 1 FROM transactions WHERE transaction_id=?1 AND status=?2 AND credit_granted_micros=?3 AND clawed_back_micros=?4 AND revoked_at IS ?5)", c.transactionId,row.status,row.credit_granted_micros,row.clawed_back_micros,row.revoked_at)
      : assertSql(db, "NOT EXISTS(SELECT 1 FROM transactions WHERE transaction_id=?1)", c.transactionId));
    stmts.push(db.prepare(`INSERT INTO storekit_states(transaction_id,signed_date,revoked_at,original_transaction_id,product_id,store_environment,account_token)
      VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(transaction_id) DO UPDATE SET signed_date=excluded.signed_date,revoked_at=excluded.revoked_at`)
      .bind(c.transactionId,effective.signed_date,effective.revoked_at,c.originalTransactionId,short,c.environment,c.appAccountToken));
    if (eventId) stmts.push(db.prepare("INSERT OR IGNORE INTO storekit_events VALUES(?,?,?)").bind(eventId,c.transactionId,c.signedDate));
    const balanceEnv: BalanceEnvironment = c.environment === "Production" ? "production" : "sandbox";
    if (accountId && !row) {
      stmts.push(assertSql(db, "EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND deleted_at IS NULL)", accountId),
        db.prepare("INSERT OR IGNORE INTO transaction_bindings VALUES(?,?,?)").bind(c.originalTransactionId,accountId,now),
        assertSql(db,"(SELECT account_id FROM transaction_bindings WHERE original_transaction_id=?1)=?2",c.originalTransactionId,accountId),
        db.prepare(`INSERT INTO transactions(transaction_id,original_transaction_id,account_id,product_id,store_environment,balance_environment,purchase_date,status,revoked_at,created_at)
          VALUES(?,?,?,?,?,?,?,'pending_prerequisite',?,?)`).bind(c.transactionId,c.originalTransactionId,accountId,short,c.environment,balanceEnv,c.purchaseDate,effective.revoked_at,now));
    }
    if (row && row.revoked_at !== effective.revoked_at) {
      const key = `state:${c.transactionId}:${effective.signed_date}`;
      stmts.push(assertSql(db,"(SELECT revoked_at FROM transactions WHERE transaction_id=?1) IS ?2",c.transactionId,row.revoked_at));
      if (effective.revoked_at !== null && row.revoked_at === null && row.credit_granted_micros > 0) {
        stmts.push(db.prepare(`INSERT INTO ledger(account_id,source,environment,kind,amount_micros,idempotency_key,ref,created_at)
          SELECT t.account_id,'balance',t.balance_environment,'clawback',-MIN(t.credit_granted_micros,COALESCE(b.micros,0)),?2,t.transaction_id,?3
          FROM transactions t LEFT JOIN balances b ON b.account_id=t.account_id AND b.environment=t.balance_environment WHERE t.transaction_id=?1`).bind(c.transactionId,key,now),
          db.prepare("UPDATE balances SET micros=micros+(SELECT amount_micros FROM ledger WHERE idempotency_key=?3),updated_at=?4 WHERE account_id=?1 AND environment=?2").bind(row.account_id,balanceEnv,key,now),
          db.prepare("UPDATE transactions SET clawed_back_micros=-(SELECT amount_micros FROM ledger WHERE idempotency_key=?2),shortfall_micros=credit_granted_micros+(SELECT amount_micros FROM ledger WHERE idempotency_key=?2) WHERE transaction_id=?1").bind(c.transactionId,key));
      } else if (effective.revoked_at === null && row.revoked_at !== null && row.clawed_back_micros > 0) {
        stmts.push(ledgerInsert(db,{accountId:row.account_id,source:"balance",environment:balanceEnv,kind:"clawback_reversal",amount:row.clawed_back_micros,key,ref:c.transactionId,now}),
          balanceDelta(db,row.account_id,balanceEnv,row.clawed_back_micros,now),
          db.prepare("UPDATE transactions SET clawed_back_micros=0,shortfall_micros=0 WHERE transaction_id=?").bind(c.transactionId));
      }
      stmts.push(db.prepare("UPDATE transactions SET revoked_at=?2 WHERE transaction_id=?1").bind(c.transactionId,effective.revoked_at));
    }
    try { await db.batch(stmts); break; }
    catch(e) { if (!isGuardFailure(e) || attempt===4) throw e; }
  }
  // Durable pending rows are repaired on replay and by maintenance. Grants and eligibility rechecks are atomic.
  await releasePending(env, accountId ?? c.appAccountToken, now);
}
export async function releasePending(env: Env, accountId: string, now: number): Promise<void> {
  const db = env.DB;
  const pending = await db.prepare("SELECT * FROM transactions WHERE account_id=? AND status='pending_prerequisite' AND revoked_at IS NULL LIMIT 100").bind(accountId).all<TxRow>();
  for (const row of pending.results) {
    let def: ProductDef;
    try { def = product(env, PRODUCT_PREFIX + row.product_id).def; }
    catch (e) { if (e instanceof HttpError && ["UNKNOWN_PRODUCT","PRODUCT_DISABLED"].includes(e.code)) continue; throw e; }
    const eligible = def.requires ? "EXISTS(SELECT 1 FROM transactions WHERE account_id=?1 AND store_environment=?2 AND product_id=?3 AND status='granted' AND revoked_at IS NULL)" : "1";
    try {
      await db.batch([
        assertSql(db,"EXISTS(SELECT 1 FROM transactions WHERE transaction_id=?1 AND status='pending_prerequisite' AND revoked_at IS NULL)",row.transaction_id),
        assertSql(db,eligible,...(def.requires ? [accountId,row.store_environment,def.requires] : [])),
        db.prepare("UPDATE transactions SET status='granted',credit_granted_micros=?2 WHERE transaction_id=?1").bind(row.transaction_id,def.credit),
        ...grantStatements(db,{accountId,environment:row.balance_environment,amount:def.credit,key:`grant:${row.transaction_id}`,ref:row.transaction_id,now}),
      ]);
    } catch(e) { if (!isGuardFailure(e)) throw e; }
  }
}
export async function postTransaction(ctx: AuthedCtx, input: Record<string, unknown>): Promise<Response> {
  const claims = parseClaims(await verifyAppleJws(input.signed_transaction,ctx.deps.trustedRoots),ctx);
  await reconcileVerified(ctx,claims,ctx.accountId);
  // A prerequisite and upgrade may have raced; a second pass reaches dependent grants after either insertion order.
  await releasePending(ctx.env,ctx.accountId,ctx.deps.now());
  const row = await ctx.env.DB.prepare("SELECT * FROM transactions WHERE transaction_id=?").bind(claims.transactionId).first<TxRow>();
  return json({transaction_id:claims.transactionId,product_id:claims.productId,environment:claims.environment,
    status:row?.revoked_at ? "revoked" : row?.status,credit_granted_micros:row?.credit_granted_micros ?? 0,
    balances:await getBalances(ctx.env.DB,ctx.accountId),entitlements:await getEntitlements(ctx.env.DB,ctx.accountId,entitlementEnvironment(ctx.env))});
}
export async function postNotification(ctx: Ctx, input: Record<string, unknown>): Promise<Response> {
  const outer = await verifyAppleJws(input.signedPayload,ctx.deps.trustedRoots);
  if (!["REFUND","REVOKE","REFUND_REVERSED"].includes(String(outer.notificationType))) return json({ok:true,handled:false});
  if (!isUuid(outer.notificationUUID)) throw invalidJws("Missing notification UUID.");
  const data = outer.data as Record<string,unknown> | undefined;
  if (!data || data.bundleId !== ctx.env.BUNDLE_ID) throw invalidJws("Invalid notification data.");
  const claims = parseClaims(await verifyAppleJws(data.signedTransactionInfo,ctx.deps.trustedRoots),ctx);
  if ((outer.notificationType === "REFUND_REVERSED") !== (claims.revocationDate === null)) {
    throw new HttpError(409,"AMBIGUOUS_PURCHASE_STATE","The notification and signed transaction disagree; fresh transaction state is required.");
  }
  await reconcileVerified(ctx,claims,null,outer.notificationUUID);
  return json({ok:true,handled:true});
}
