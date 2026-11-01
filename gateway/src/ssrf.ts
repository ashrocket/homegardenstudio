import { HttpError } from "./errors";

export const OPENAI_HOST = "api.openai.com";
export const ANTHROPIC_HOST = "api.anthropic.com";
/** Hosts that must use their own provider type. A custom endpoint may not match them exactly or by suffix. */
export const PROVIDER_HOSTS = [OPENAI_HOST, ANTHROPIC_HOST];

const BLOCKED_SUFFIXES = [
  ".localhost",
  ".local",
  ".internal",
  ".lan",
  ".home",
  ".corp",
  ".arpa",
  ".localdomain",
  ".intranet",
  ".private",
];

export interface ValidatedEndpoint {
  /** Normalised https URL without a trailing slash. This exact string is what the credential is sent to. */
  url: string;
  host: string;
}

function reject(reason: string): never {
  throw new HttpError(400, "INVALID_ENDPOINT", `Custom endpoint rejected: ${reason}.`);
}

/**
 * Accepts only a public https URL on port 443 with a real DNS name. Cloudflare Workers cannot resolve a name
 * before fetching it, so a name that points at a private address is stopped by the platform, not here.
 */
export function validateCustomEndpoint(raw: unknown, providerHosts: string[] = PROVIDER_HOSTS): ValidatedEndpoint {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 2048) reject("endpoint must be a string of 1-2048 characters");
  if (/[\s\u0000-\u001f\u007f\\]/.test(raw)) reject("endpoint contains whitespace, control characters or a backslash");
  if (!/^https:\/\//i.test(raw)) reject("only https:// URLs are allowed");
  if (raw.includes("#")) reject("fragments are not allowed");
  if (raw.includes("?")) reject("query strings are not allowed");
  if (raw.includes("@")) reject("userinfo is not allowed");

  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return reject("not a valid URL");
  }
  if (u.protocol !== "https:") reject("only https:// URLs are allowed");
  if (u.username !== "" || u.password !== "") reject("userinfo is not allowed");
  if (u.port !== "") reject("only the default port 443 is allowed");
  if (u.search !== "" || u.hash !== "") reject("query strings and fragments are not allowed");

  // The URL parser has already turned decimal/octal/hex IPv4 forms into dotted quads and wrapped IPv6 in brackets.
  const host = u.hostname.toLowerCase();
  if (host.startsWith("[") || host.includes(":")) reject("IP address literals are not allowed");
  if (host.endsWith(".")) reject("trailing-dot hostnames are not allowed");
  const labels = host.split(".");
  if (labels.length < 2) reject("hostname must contain a dot");
  if (labels.some((l) => l.length === 0 || l.length > 63 || !/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(l))) {
    reject("hostname is not a plain DNS name");
  }
  const last = labels[labels.length - 1] ?? "";
  // A purely numeric or 0x... final label is an IPv4 form (or cannot be a public TLD).
  if (/^(0x[0-9a-f]*|[0-9]+)$/.test(last)) reject("IP address literals are not allowed");
  if (host === "localhost" || BLOCKED_SUFFIXES.some((s) => host.endsWith(s))) reject("local and internal names are not allowed");
  for (const p of providerHosts) {
    if (host === p || host.endsWith(`.${p}`)) reject("provider hosts must use their own provider type");
  }

  const path = u.pathname.replace(/\/+$/, "");
  return { url: `https://${host}${path}`, host };
}

export class UpstreamError extends HttpError {
  constructor(code: "UPSTREAM_REDIRECT" | "UPSTREAM_UNREACHABLE" | "UPSTREAM_TIMEOUT", message: string) {
    super(502, code, message);
  }
}

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

/**
 * The only way the Worker talks to a provider. It pins the host, refuses redirects (a 3xx is a failure and the
 * Location is never followed, so the credential cannot be forwarded) and bounds the wait.
 */
export async function upstreamFetch(
  doFetch: FetchLike,
  url: string,
  init: RequestInit,
  opts: { expectHost: string; timeoutMs: number },
): Promise<Response> {
  let target: URL;
  try {
    target = new URL(url);
  } catch {
    throw new UpstreamError("UPSTREAM_UNREACHABLE", "The provider address is invalid.");
  }
  if (target.protocol !== "https:" || target.hostname.toLowerCase() !== opts.expectHost || target.port !== "") {
    // Defence in depth: the host is never guessed or taken from a response.
    throw new UpstreamError("UPSTREAM_UNREACHABLE", "Refusing to send a credential to an unexpected host.");
  }
  let res: Response;
  try {
    res = await doFetch(target.href, { ...init, redirect: "manual", signal: AbortSignal.timeout(opts.timeoutMs) });
  } catch (e) {
    const name = e instanceof Error ? e.name : "";
    if (name === "TimeoutError" || name === "AbortError") throw new UpstreamError("UPSTREAM_TIMEOUT", "The provider did not answer in time.");
    throw new UpstreamError("UPSTREAM_UNREACHABLE", "The provider could not be reached.");
  }
  if (res.status >= 300 && res.status < 400) {
    try {
      await res.body?.cancel();
    } catch {
      /* ignore */
    }
    throw new UpstreamError("UPSTREAM_REDIRECT", "The provider answered with a redirect, which is not followed.");
  }
  return res;
}
