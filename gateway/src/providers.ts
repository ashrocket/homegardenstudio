import { boundedJson } from "./bounded";
import Anthropic from "@anthropic-ai/sdk";
import { HttpError } from "./errors";
import { ANTHROPIC_HOST, OPENAI_HOST, upstreamFetch } from "./ssrf";
import type { Deps, Env } from "./types";
import { toBase64, fromBase64 } from "./util";

export const DEFAULT_IMAGE_MODELS = ["gpt-image-2.5-sunburst", "gpt-image-2.5-flare", "gpt-image-2"];
export const OPENAI_BASE = `https://${OPENAI_HOST}/v1`;

/** The configured allow-list of image model ids (IMAGE_MODELS, a JSON array). Falls back to the defaults. */
export function imageModels(env: Env): string[] {
  if (!env.IMAGE_MODELS) return DEFAULT_IMAGE_MODELS;
  try {
    const v: unknown = JSON.parse(env.IMAGE_MODELS);
    if (Array.isArray(v) && v.length > 0 && v.every((m) => typeof m === "string" && /^[A-Za-z0-9._:-]{1,80}$/.test(m))) return v as string[];
  } catch {
    /* fall through */
  }
  return DEFAULT_IMAGE_MODELS;
}

/** An OpenAI-compatible destination. The credential only ever goes to `host`. */
export interface OpenAiTarget {
  base: string;
  host: string;
  secret: string;
}

export const openaiTarget = (secret: string): OpenAiTarget => ({ base: OPENAI_BASE, host: OPENAI_HOST, secret });

export function customTarget(secret: string, endpoint: string, host: string): OpenAiTarget {
  return { base: endpoint, host, secret };
}

const bearer = (t: OpenAiTarget) => ({ authorization: `Bearer ${t.secret}` });

function providerFailed(message: string, upstreamStatus?: number): HttpError {
  return new HttpError(502, "PROVIDER_FAILED", message, upstreamStatus === undefined ? {} : { upstream_status: upstreamStatus });
}

/** Walks an error's `cause` chain looking for an UpstreamError raised inside the Anthropic SDK's fetch. */
function findUpstream(e: unknown): HttpError | null {
  for (let i = 0, cur: unknown = e; i < 5 && cur; i++, cur = (cur as { cause?: unknown }).cause) {
    if (cur instanceof HttpError) return cur;
  }
  return null;
}

export interface KeyTestResult {
  ok: boolean;
  status: number;
  capabilities: { image_generation: boolean; text: boolean };
  message: string;
  discovery: "available" | "invalid_response";
  generation_verified: false;
  advertised_image_models?: string[];
}

const rejected = (status: number): KeyTestResult => ({
  ok: false,
  status,
  discovery: "invalid_response",
  generation_verified: false,
  capabilities: { image_generation: false, text: false },
  message: status === 401 || status === 403 ? "The provider rejected this key." : `The provider answered with status ${status}.`,
});

/** GET <base>/models with the stored credential. Used for openai and custom keys. */
async function testOpenAiLike(deps: Deps, env: Env, t: OpenAiTarget): Promise<KeyTestResult> {
  const res = await upstreamFetch(deps.fetch, `${t.base}/models`, { method: "GET", headers: { ...bearer(t), accept: "application/json" } }, { expectHost: t.host, timeoutMs: 10_000 });
  if (!res.ok) {
    await res.body?.cancel();
    return rejected(res.status);
  }
  let ids: string[] = [];
  try {
    const j = (await boundedJson(res, 256 * 1024)) as { data?: Array<{ id?: unknown }> };
    if (!Array.isArray(j.data) || !j.data.every(m => m && typeof m.id === "string")) throw new Error("invalid models");
    ids = j.data.map((m) => m.id as string);
  } catch {
    return { ok: false, status: res.status, discovery: "invalid_response", generation_verified: false, capabilities: { image_generation: false, text: false }, message: "The endpoint did not return a valid model list. Credential access is unverified." };
  }
  const allowed = new Set(imageModels(env));
  const image = ids.some((id) => allowed.has(id));
  return {
    ok: true,
    status: res.status,
    capabilities: { image_generation: false, text: false },
    discovery: "available", generation_verified: false, advertised_image_models: ids.filter(id => allowed.has(id)),
    message: image ? "The endpoint accepted model discovery and advertises supported image models. Generation permission and billing are unverified." : "The endpoint accepted model discovery. Generation permission and billing are unverified.",
  };
}

function anthropicClient(deps: Deps, secret: string, timeoutMs: number): Anthropic {
  const pinned = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const response = await upstreamFetch(deps.fetch, url, init ?? {}, { expectHost: ANTHROPIC_HOST, timeoutMs });
    const data = await boundedJson(response, 256 * 1024, timeoutMs);
    // The SDK normalizes missing model data to [], so validate the wire shape before constructing its Page.
    if (response.ok && new URL(url).pathname === "/v1/models" && (!data || typeof data !== "object" || !Array.isArray((data as { data?: unknown }).data))) {
      throw new HttpError(502,"INVALID_PROVIDER_RESPONSE","Anthropic returned an invalid model list.");
    }
    return new Response(JSON.stringify(data), { status: response.status, headers: { "content-type": "application/json" } });
  };
  return new Anthropic({ apiKey: secret, fetch: pinned as typeof fetch, maxRetries: 0, timeout: timeoutMs });
}

async function testAnthropic(deps: Deps, secret: string): Promise<KeyTestResult> {
  const client = anthropicClient(deps, secret, 10_000);
  try {
    const page = await client.models.list({ limit: 1 });
    if (!Array.isArray(page.data) || !page.data.every(model => model && typeof model.id === "string")) {
      return { ok: false, status: 200, discovery: "invalid_response", generation_verified: false, capabilities: { image_generation: false, text: false }, message: "Anthropic returned an invalid model list; credential access is unverified." };
    }
    return { ok: true, status: 200, capabilities: { image_generation: false, text: false }, discovery: "available", generation_verified: false, message: "Anthropic accepted model discovery. Text generation permission and billing are unverified. Anthropic does not generate images." };
  } catch (e) {
    const up = findUpstream(e);
    if (up?.code === "INVALID_PROVIDER_RESPONSE") return { ok:false,status:502,discovery:"invalid_response",generation_verified:false,capabilities:{image_generation:false,text:false},message:"Anthropic returned an invalid model list; credential access is unverified." };
    if (up) throw up;
    if (e instanceof Anthropic.APIError && typeof e.status === "number") return rejected(e.status);
    throw providerFailed("The provider could not be reached.");
  }
}

export async function testProviderKey(
  deps: Deps,
  env: Env,
  provider: "openai" | "anthropic" | "custom",
  secret: string,
  endpoint: { url: string; host: string } | null,
): Promise<KeyTestResult> {
  if (provider === "anthropic") return testAnthropic(deps, secret);
  if (provider === "openai") return testOpenAiLike(deps, env, openaiTarget(secret));
  if (!endpoint) throw new HttpError(500, "INTERNAL", "Custom key has no endpoint.");
  return testOpenAiLike(deps, env, customTarget(secret, endpoint.url, endpoint.host));
}

export interface ImageParams {
  model: string;
  prompt: string;
  size: string;
  quality: string;
  layoutPng: Uint8Array;
  source: { bytes: Uint8Array; mediaType: "image/jpeg" | "image/png" } | null;
}

const MAX_IMAGE_RESPONSE_B64 = 8 * 1024 * 1024;

/** POST <base>/images/edits: the layout PNG first, then the optional source photo. Returns base64 PNG. */
export async function imageEdit(deps: Deps, t: OpenAiTarget, p: ImageParams): Promise<string> {
  const form = new FormData();
  form.set("model", p.model);
  form.set("prompt", p.prompt);
  form.append("image[]", new Blob([p.layoutPng], { type: "image/png" }), "layout.png");
  if (p.source) {
    form.append("image[]", new Blob([p.source.bytes], { type: p.source.mediaType }), p.source.mediaType === "image/png" ? "photo.png" : "photo.jpg");
  }
  form.set("size", p.size);
  form.set("quality", p.quality);
  form.set("n", "1");
  form.set("output_format", "png");
  const res = await upstreamFetch(deps.fetch, `${t.base}/images/edits`, { method: "POST", headers: { ...bearer(t) }, body: form }, { expectHost: t.host, timeoutMs: 170_000 });
  if (!res.ok) {
    await res.body?.cancel();
    throw providerFailed(`The provider rejected the render request (status ${res.status}).`, res.status);
  }
  let b64: unknown;
  try {
    const j = (await boundedJson(res, MAX_IMAGE_RESPONSE_B64 + 1024, 170_000)) as { data?: Array<{ b64_json?: unknown }> };
    b64 = j.data?.[0]?.b64_json;
  } catch {
    throw providerFailed("The provider returned an unreadable response.");
  }
  if (typeof b64 !== "string" || b64.length === 0 || b64.length > MAX_IMAGE_RESPONSE_B64) {
    throw providerFailed("The provider returned no image.");
  }
  try { const bytes=fromBase64(b64); if(bytes[0]!==137 || bytes[1]!==80 || bytes[2]!==78 || bytes[3]!==71) throw new Error(); }
  catch { throw providerFailed("The provider returned invalid PNG image data."); }
  return b64;
}

export async function anthropicText(deps: Deps, secret: string, model: string, system: string, user: string): Promise<string> {
  const client = anthropicClient(deps, secret, 90_000);
  let msg: Anthropic.Message;
  try {
    msg = await client.messages.create({
      model,
      max_tokens: 4096,
      system,
      output_config: { effort: "low" },
      messages: [{ role: "user", content: user }],
    });
  } catch (e) {
    const up = findUpstream(e);
    if (up) throw up;
    if (e instanceof Anthropic.APIError && typeof e.status === "number") {
      throw providerFailed(`The provider rejected the request (status ${e.status}).`, e.status);
    }
    throw providerFailed("The provider could not be reached.");
  }
  if (msg.stop_reason === "refusal") {
    throw new HttpError(422, "PROVIDER_REFUSED", "The provider declined to answer this request. Try rewording the question.");
  }
  const text = msg.content
    .filter((b): b is Anthropic.TextBlock => b.type === "text")
    .map((b) => b.text)
    .join("\n")
    .trim();
  if (!text) throw providerFailed("The provider returned no text.");
  return text;
}

/** POST <base>/chat/completions for openai and custom assist. */
export async function chatText(deps: Deps, t: OpenAiTarget, model: string, system: string, user: string, isCustom: boolean): Promise<string> {
  const payload: Record<string, unknown> = {
    model,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
  };
  payload[isCustom ? "max_tokens" : "max_completion_tokens"] = 2000;
  const res = await upstreamFetch(
    deps.fetch,
    `${t.base}/chat/completions`,
    { method: "POST", headers: { ...bearer(t), "content-type": "application/json" }, body: JSON.stringify(payload) },
    { expectHost: t.host, timeoutMs: 90_000 },
  );
  if (!res.ok) {
    await res.body?.cancel();
    throw providerFailed(`The provider rejected the request (status ${res.status}).`, res.status);
  }
  try {
    const j = (await boundedJson(res, 256 * 1024, 90_000)) as { choices?: Array<{ message?: { content?: unknown } }> };
    const c = j.choices?.[0]?.message?.content;
    if (typeof c === "string" && c.trim()) return c.trim();
  } catch {
    /* fall through */
  }
  throw providerFailed("The provider returned no text.");
}

export { toBase64 };
