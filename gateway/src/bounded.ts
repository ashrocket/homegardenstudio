import { HttpError } from "./errors";

/** Cancel on excess bytes, invalid JSON or a stalled body, including dishonest Content-Length. */
export async function boundedJson(response: Response, maxBytes: number, timeoutMs = 10_000): Promise<unknown> {
  if (!response.headers.get("content-type")?.toLowerCase().includes("application/json")) {
    await response.body?.cancel();
    throw new HttpError(502, "INVALID_PROVIDER_RESPONSE", "The provider did not return JSON.");
  }
  if (Number(response.headers.get("content-length")) > maxBytes) {
    await response.body?.cancel();
    throw new HttpError(502, "PROVIDER_RESPONSE_TOO_LARGE", "The provider response exceeded the limit.");
  }
  const reader = response.body?.getReader();
  if (!reader) throw new HttpError(502, "INVALID_PROVIDER_RESPONSE", "The provider returned no data.");
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => { void reader.cancel().catch(() => {}); reject(new HttpError(502, "UPSTREAM_TIMEOUT", "The provider response timed out.")); }, timeoutMs);
  });
  try {
    const chunks: Uint8Array[] = [];
    let length = 0;
    for (;;) {
      const next = await Promise.race([reader.read(), deadline]);
      if (next.done) break;
      length += next.value.length;
      if (length > maxBytes) throw new HttpError(502, "PROVIDER_RESPONSE_TOO_LARGE", "The provider response exceeded the limit.");
      chunks.push(next.value);
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    try { return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)); }
    catch { throw new HttpError(502, "INVALID_PROVIDER_RESPONSE", "The provider returned malformed JSON."); }
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
    void reader.cancel().catch(() => {});
  }
}
