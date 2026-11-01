import { HttpError, badRequest, notFound } from "./errors";
import { logEvent } from "./redact";
import { validateCustomEndpoint } from "./ssrf";
import type { Env, Provider } from "./types";
import { fromBase64, isoOrNull, sha256Hex, toBase64, utf8 } from "./util";

export const PROVIDERS: Provider[] = ["openai", "anthropic", "custom"];
export const isProvider = (s: string): s is Provider => (PROVIDERS as string[]).includes(s);

const HKDF_INFO = "hgs-provider-key-v1";

export interface KeyRow {
  account_id: string;
  provider: Provider;
  ciphertext: string;
  iv: string;
  kek_version: number;
  label: string | null;
  fingerprint: string;
  endpoint: string | null;
  endpoint_host: string | null;
  created_at: number;
  updated_at: number;
}

export interface KeyMeta {
  provider: Provider;
  label: string | null;
  fingerprint: string;
  endpoint_host: string | null;
  created_at: string;
  updated_at: string;
}

export const toKeyMeta = (r: KeyRow): KeyMeta => ({
  provider: r.provider,
  label: r.label,
  fingerprint: r.fingerprint,
  endpoint_host: r.endpoint_host,
  created_at: isoOrNull(r.created_at) as string,
  updated_at: isoOrNull(r.updated_at) as string,
});

export function custodyUnavailable(): HttpError {
  return new HttpError(503, "CUSTODY_UNAVAILABLE", "Key custody is not available right now.");
}

export function currentKekVersion(env: Env): number {
  const n = Number(env.KEK_CURRENT_VERSION);
  if (!Number.isSafeInteger(n) || n < 1) throw custodyUnavailable();
  return n;
}

function kekBytes(env: Env, version: number): Uint8Array {
  const b64 = env[`KEK_${version}` as `KEK_${number}`];
  if (!b64) throw custodyUnavailable();
  let bytes: Uint8Array;
  try {
    bytes = fromBase64(b64.trim());
  } catch {
    throw custodyUnavailable();
  }
  if (bytes.length !== 32) throw custodyUnavailable();
  return bytes;
}

/** AES-256-GCM key = HKDF-SHA256(ikm = KEK_n, salt = account id, info = "hgs-provider-key-v1"). */
async function deriveKey(env: Env, accountId: string, version: number): Promise<CryptoKey> {
  const ikm = await crypto.subtle.importKey("raw", kekBytes(env, version), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: utf8(accountId), info: utf8(HKDF_INFO) },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/** Binds a ciphertext to its account, provider and KEK version. A copy under another account fails to decrypt. */
export const aad = (accountId: string, provider: string, version: number): Uint8Array =>
  utf8(`hgs1|${accountId}|${provider}|${version}`);

export async function encryptSecret(
  env: Env,
  accountId: string,
  provider: string,
  plaintext: string,
  version = currentKekVersion(env),
): Promise<{ ciphertext: string; iv: string; kek_version: number }> {
  const key = await deriveKey(env, accountId, version);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: aad(accountId, provider, version) },
    key,
    utf8(plaintext),
  );
  return { ciphertext: toBase64(new Uint8Array(ct)), iv: toBase64(iv), kek_version: version };
}

export async function decryptSecret(
  env: Env,
  accountId: string,
  provider: string,
  row: Pick<KeyRow, "ciphertext" | "iv" | "kek_version">,
): Promise<string> {
  const key = await deriveKey(env, accountId, row.kek_version);
  try {
    const pt = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: fromBase64(row.iv), additionalData: aad(accountId, provider, row.kek_version) },
      key,
      fromBase64(row.ciphertext),
    );
    return new TextDecoder().decode(pt);
  } catch {
    // Wrong account, wrong provider, wrong KEK version or tampering. Never say which.
    throw new HttpError(500, "CUSTODY_ERROR", "The stored key could not be decrypted.");
  }
}

const PRINTABLE_ASCII = /^[\x21-\x7e]{20,400}$/;
const LABEL_OK = /^[^\u0000-\u001f\u007f]{1,64}$/u;

function checkKeyFormat(provider: Provider, secret: string): void {
  if (provider === "anthropic" && !secret.startsWith("sk-ant-")) {
    throw badRequest(
      "KEY_PROVIDER_MISMATCH",
      secret.startsWith("sk-") ? "This looks like an OpenAI key. Save it under OpenAI instead." : "This does not look like an Anthropic key (they start with sk-ant-).",
    );
  }
  if (provider === "openai") {
    if (secret.startsWith("sk-ant-")) throw badRequest("KEY_PROVIDER_MISMATCH", "This looks like an Anthropic key. Save it under Anthropic instead.");
    if (!secret.startsWith("sk-")) throw badRequest("KEY_PROVIDER_MISMATCH", "This does not look like an OpenAI key (they start with sk-).");
  }
}

export async function putKey(env: Env, accountId: string, provider: Provider, body: Record<string, unknown>, now: number): Promise<KeyMeta> {
  if (body.confirmed_provider !== provider) {
    throw badRequest("PROVIDER_NOT_CONFIRMED", "confirmed_provider must equal the provider in the URL.");
  }
  const secret = body.secret;
  if (typeof secret !== "string" || !PRINTABLE_ASCII.test(secret)) {
    throw badRequest("INVALID_SECRET", "The key must be 20-400 printable ASCII characters with no spaces.");
  }
  checkKeyFormat(provider, secret);

  let label: string | null = null;
  if (body.label !== undefined && body.label !== null) {
    if (typeof body.label !== "string" || !LABEL_OK.test(body.label.trim())) {
      throw badRequest("INVALID_LABEL", "The label must be 1-64 characters without control characters.");
    }
    label = body.label.trim();
  }

  let endpoint: string | null = null;
  let endpointHost: string | null = null;
  if (provider === "custom") {
    if (body.endpoint === undefined) throw badRequest("ENDPOINT_REQUIRED", "A custom key needs an endpoint.");
    const v = validateCustomEndpoint(body.endpoint);
    endpoint = v.url;
    endpointHost = v.host;
  } else if (body.endpoint !== undefined) {
    throw badRequest("ENDPOINT_NOT_ALLOWED", "Only custom keys take an endpoint.");
  }

  const enc = await encryptSecret(env, accountId, provider, secret);
  const fingerprint = (await sha256Hex(secret)).slice(0, 12);
  await env.DB.prepare(
    `INSERT INTO provider_keys (account_id, provider, ciphertext, iv, kek_version, label, fingerprint, endpoint, endpoint_host, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
     ON CONFLICT (account_id, provider) DO UPDATE SET
       ciphertext = excluded.ciphertext, iv = excluded.iv, kek_version = excluded.kek_version, label = excluded.label,
       fingerprint = excluded.fingerprint, endpoint = excluded.endpoint, endpoint_host = excluded.endpoint_host,
       updated_at = excluded.updated_at`,
  )
    .bind(accountId, provider, enc.ciphertext, enc.iv, enc.kek_version, label, fingerprint, endpoint, endpointHost, now)
    .run();
  const row = await getKeyRow(env.DB, accountId, provider);
  if (!row) throw new HttpError(500, "INTERNAL", "Key was not stored.");
  return toKeyMeta(row);
}

export async function getKeyRow(db: D1Database, accountId: string, provider: Provider): Promise<KeyRow | null> {
  return db.prepare("SELECT * FROM provider_keys WHERE account_id = ?1 AND provider = ?2").bind(accountId, provider).first<KeyRow>();
}

export async function listKeyMetas(db: D1Database, accountId: string): Promise<KeyMeta[]> {
  const { results } = await db.prepare("SELECT * FROM provider_keys WHERE account_id = ?1 ORDER BY provider").bind(accountId).all<KeyRow>();
  return results.map(toKeyMeta);
}

export async function deleteKey(db: D1Database, accountId: string, provider: Provider): Promise<void> {
  await db.prepare("DELETE FROM provider_keys WHERE account_id = ?1 AND provider = ?2").bind(accountId, provider).run();
}

/** Decrypts in memory for one outbound call. The plaintext is never returned from any route. */
export async function loadSecret(
  env: Env,
  accountId: string,
  provider: Provider,
): Promise<{ secret: string; row: KeyRow }> {
  const row = await getKeyRow(env.DB, accountId, provider);
  if (!row) throw notFound("KEY_NOT_FOUND", `No ${provider} key is stored for this account.`);
  return { secret: await decryptSecret(env, accountId, provider, row), row };
}

export interface RotationResult {
  rotated: number;
  failed: number;
  remaining: number;
  current_version: number;
}

const ROTATE_BATCH = 100;
const ROTATE_MAX_BATCHES = 5;

/** Re-encrypts rows below the current KEK version, 100 per batch. Call again while `remaining` > 0. */
export async function rotateKeys(env: Env, now: number): Promise<RotationResult> {
  const current = currentKekVersion(env);
  kekBytes(env, current); // fail with 503 before touching any row
  let rotated = 0;
  let failed = 0;
  const skip = new Set<string>();
  for (let b = 0; b < ROTATE_MAX_BATCHES; b++) {
    const { results } = await env.DB.prepare(
      "SELECT * FROM provider_keys WHERE kek_version < ?1 ORDER BY account_id, provider LIMIT ?2",
    )
      .bind(current, ROTATE_BATCH + skip.size)
      .all<KeyRow>();
    const rows = results.filter((r) => !skip.has(`${r.account_id}|${r.provider}`)).slice(0, ROTATE_BATCH);
    if (rows.length === 0) break;
    const stmts: D1PreparedStatement[] = [];
    for (const r of rows) {
      try {
        const secret = await decryptSecret(env, r.account_id, r.provider, r);
        const enc = await encryptSecret(env, r.account_id, r.provider, secret, current);
        // Compare-and-set on the old ciphertext so a concurrent PUT is never overwritten.
        stmts.push(
          env.DB.prepare(
            "UPDATE provider_keys SET ciphertext = ?1, iv = ?2, kek_version = ?3, updated_at = ?4 WHERE account_id = ?5 AND provider = ?6 AND ciphertext = ?7",
          ).bind(enc.ciphertext, enc.iv, enc.kek_version, now, r.account_id, r.provider, r.ciphertext),
        );
      } catch (e) {
        failed++;
        skip.add(`${r.account_id}|${r.provider}`);
        logEvent("error", "custody.rotate_row_failed", { provider: r.provider, kek_version: r.kek_version, error: e });
      }
    }
    if (stmts.length) {
      const results = await env.DB.batch(stmts);
      rotated += results.reduce((sum, r) => sum + r.meta.changes, 0);
    }
  }
  const left = await env.DB.prepare("SELECT COUNT(*) AS n FROM provider_keys WHERE kek_version < ?1").bind(current).first<{ n: number }>();
  return { rotated, failed, remaining: left?.n ?? 0, current_version: current };
}
