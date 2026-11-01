import { HttpError } from "./errors";

const encoder = new TextEncoder();
export const utf8 = (s: string): Uint8Array => encoder.encode(s);

export function toBase64(bytes: Uint8Array): string {
  let s = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) s += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(s);
}

const B64_RE = /^[A-Za-z0-9+/]*={0,2}$/;
/** Strict standard-base64 decode. Throws on anything malformed. */
export function fromBase64(b64: string): Uint8Array {
  if (b64.length % 4 !== 0 || !B64_RE.test(b64)) throw new Error("invalid base64");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const B64URL_RE = /^[A-Za-z0-9_-]*$/;
export function fromBase64Url(s: string): Uint8Array {
  if (!B64URL_RE.test(s) || s.length % 4 === 1) throw new Error("invalid base64url");
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  return fromBase64(padded);
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256(data: Uint8Array | string): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? utf8(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}
export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  return toHex(await sha256(data));
}

export function randomBytes(n: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(n));
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const isUuid = (s: unknown): s is string => typeof s === "string" && UUID_RE.test(s);

/** Compares two strings without leaking where they differ: both are hashed first. */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256(a), sha256(b)]);
  let diff = 0;
  for (let i = 0; i < ha.length; i++) diff |= (ha[i] ?? 0) ^ (hb[i] ?? 0);
  return diff === 0;
}

export const BODY_LIMIT_DEFAULT = 64 * 1024;
export const BODY_LIMIT_RENDER = 12 * 1024 * 1024;

/** Reads a request body as text, refusing anything over `maxBytes` even without Content-Length. */
export async function readLimitedText(request: Request, maxBytes: number): Promise<string> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > maxBytes) throw tooLarge(maxBytes);
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw tooLarge(maxBytes);
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    all.set(c, off);
    off += c.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(all);
}

function tooLarge(max: number): HttpError {
  return new HttpError(413, "PAYLOAD_TOO_LARGE", `Request body is limited to ${max} bytes.`);
}

export async function readJsonObject(request: Request, maxBytes = BODY_LIMIT_DEFAULT): Promise<Record<string, unknown>> {
  let text: string;
  try {
    text = await readLimitedText(request, maxBytes);
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(400, "INVALID_BODY", "Request body must be UTF-8 JSON.");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new HttpError(400, "INVALID_BODY", "Request body must be a JSON object.");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpError(400, "INVALID_BODY", "Request body must be a JSON object.");
  }
  return parsed as Record<string, unknown>;
}

export const isoOrNull = (ms: number | null | undefined): string | null =>
  ms === null || ms === undefined ? null : new Date(ms).toISOString();

export function isInt(v: unknown): v is number {
  return typeof v === "number" && Number.isSafeInteger(v);
}

/** The error message D1 raises when a batch statement trips a constraint or an assertion. */
export function isGuardFailure(e: unknown): boolean {
  const msg = e instanceof Error ? e.message : String(e);
  return /constraint failed|integer overflow|SQLITE_CONSTRAINT/i.test(msg);
}
