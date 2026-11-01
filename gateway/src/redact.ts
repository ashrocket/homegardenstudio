/** Masks anything that looks like a credential. Applied to every string that reaches a log line. */
const PATTERNS: Array<[RegExp, string]> = [
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{4,}/gi, "Bearer [redacted]"],
  [/\b(x-api-key|authorization|api[-_]?key)(["']?\s*[:=]\s*["']?)[^\s"',}]+/gi, "$1$2[redacted]"],
  [/\bsk-[A-Za-z0-9_-]{4,}/g, "sk-[redacted]"],
  [/\bhgs_[A-Za-z0-9_-]{4,}/g, "hgs_[redacted]"],
];

export function redact(input: string): string {
  let out = input;
  for (const [re, rep] of PATTERNS) out = out.replace(re, rep);
  return out;
}

function redactValue(v: unknown, depth: number): unknown {
  if (typeof v === "string") return redact(v);
  if (v === null || typeof v === "number" || typeof v === "boolean" || v === undefined) return v;
  if (depth > 3) return "[truncated]";
  if (v instanceof Error) return { name: v.name, message: redact(v.message) };
  if (Array.isArray(v)) return v.slice(0, 20).map((x) => redactValue(x, depth + 1));
  if (typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) out[k] = redactValue(val, depth + 1);
    return out;
  }
  return "[unloggable]";
}

/**
 * Structured log line. Callers pass identifiers and counts, never request bodies, secrets,
 * Authorization headers or upstream bodies; redaction is the second line of defence.
 */
export function logEvent(level: "info" | "warn" | "error", event: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ level, event, ...(redactValue(fields, 0) as Record<string, unknown>) });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}
