# HomeGardenStudio gateway API (v1)

A Cloudflare Worker (TypeScript) with one D1 database. It handles accounts, encrypted custody of customer provider keys, verified App Store purchases, the credit ledger, cloud render and assist proxying, and sponsorship inventory. It is isolated from every other Worker: its own name `homegardenstudio-gateway` and its own D1 `homegardenstudio`.

All money is integer **micro-USD** (`1 USD = 1_000_000`). All responses are JSON. Errors are `{"error":{"code":"…","message":"…"}}` with a fitting HTTP status. Request bodies are capped at 12 MB (render) or 64 KB (everything else).

## Accounts and authentication

The design is a privacy-first anonymous account: no email and no Apple ID. The app creates an account on first need (a purchase, cloud key or render), keeps the secret in the iCloud-synchronised keychain, and sends `Authorization: Bearer <secret>`.

- `POST /v1/accounts`: returns `201 {"account_id":"<uuid v4>","secret":"hgs_<43 base64url chars>"}`. The server stores only `SHA-256(secret)`. It is rate-limited to 5 per IP per hour (`429 RATE_LIMITED`).
- `GET /v1/me`: returns `{"account_id","balances":{"production":micros,"sandbox":micros},"entitlements":{"ios":bool,"macos":bool,"bundle":bool},"monthly_cap_micros":int|null,"month_spent_micros":int,"managed_render":{"available":bool,"reason":string|null},"sponsorship_available":bool,"keys":[KeyMeta]}`.
- `PUT /v1/me/budget {"monthly_cap_micros": int|null}`: a hard monthly cap on debits from the balance. Null removes it. `0..=500_000_000`.
- `DELETE /v1/me`: deletes provider keys, sessions and sponsor windows and marks the account deleted. Financial rows (transactions, ledger) are kept without personal data for refund handling. Afterwards the secret no longer authenticates.

## Provider key custody

Providers are `openai`, `anthropic` and `custom`. `KeyMeta` is `{"provider","label","fingerprint","endpoint_host":string|null,"created_at","updated_at"}`. `fingerprint` is the first 12 hex characters of `SHA-256(secret)`. **There is no endpoint that returns plaintext.**

- `PUT /v1/keys/:provider`. Body: `{"secret":string,"confirmed_provider":string,"label"?:string,"endpoint"?:string}`.
  - `confirmed_provider` must equal `:provider`; otherwise `400 PROVIDER_NOT_CONFIRMED`.
  - Format checks:
    - `anthropic` must start with `sk-ant-`.
    - `openai` must start with `sk-` and must not start with `sk-ant-`.
    - A mismatch gives `400 KEY_PROVIDER_MISMATCH`, with a message naming the provider the key looks like.
    - The secret must be 20–400 printable ASCII characters.
  - `custom` requires `endpoint`, validated by the SSRF guard below; the others reject `endpoint`.
  - The key is stored encrypted (see Encryption). Returns `200 KeyMeta`.
- `DELETE /v1/keys/:provider`: returns `204` (idempotent).
- `POST /v1/keys/:provider/test`: decrypts in memory and makes one cheap authenticated call. For OpenAI that is `GET https://api.openai.com/v1/models`. For Anthropic it is `models.list` through `@anthropic-ai/sdk`. For a custom endpoint it is `GET <endpoint>/models`. Every call uses `redirect: "manual"` and a 10 s timeout. Returns `{"ok":bool,"status":int,"capabilities":{"image_generation":bool,"text":bool},"message":string}`. Anthropic is always `image_generation:false`. OpenAI is `image_generation:true` only when the model list includes a configured image model id. A custom endpoint is `text:true` and `image_generation` only when its `/models` lists a configured image model id. Upstream error bodies are never echoed raw; secrets are redacted in all logs.

### Encryption

- `KEK_<n>` Worker secrets (base64, 32 random bytes). `KEK_CURRENT_VERSION` (var) selects the version for new writes.
- Per record: AES-256-GCM. The key is `HKDF-SHA256(ikm=KEK_n, salt=account_id bytes, info="hgs-provider-key-v1")` and the IV is 12 random bytes. AAD is the UTF-8 of `"hgs1|" + account_id + "|" + provider + "|" + kek_version`. A ciphertext copied to another account or provider fails to decrypt.
- Rotation: `POST /v1/admin/rotate-keys` with `Authorization: Bearer <ADMIN_TOKEN secret>`. It re-encrypts rows whose `kek_version` is below current, in batches of 100. Without `ADMIN_TOKEN` configured it returns 404.
- Logs: never log request bodies, secrets, `Authorization` or upstream bodies. A `redact()` helper masks `sk-…`, `hgs_…` and bearer tokens in any logged string.

### SSRF guard (custom endpoints)

`validateCustomEndpoint(url)` accepts only:
- `https:` URLs on the default port 443, with no userinfo, no fragment and no query string;
- hostnames that aren't IP literals (v4, v6, or decimal/octal/hex forms);
- names that aren't `localhost`, don't end in `.localhost`, `.local`, `.internal`, `.lan`, `.home`, `.corp` or `.arpa`, and contain at least one dot;
- hosts that aren't an exact or suffix match of the configured provider hosts (`api.openai.com`, `api.anthropic.com`). Those must use their own provider types.

Every outbound fetch uses `redirect: "manual"`; any 3xx is treated as a failure (`UPSTREAM_REDIRECT`). Credentials are sent only to `api.openai.com` (openai), `api.anthropic.com` (anthropic) or the exact stored custom endpoint. The host is never guessed or taken from a response.

## App Store purchases

Product IDs (prefix `com.ashleyraiteri.homegardenstudio.`):

| product | type | price | credit | grants |
|---|---|---|---|---|
| `unlock.ios` | non-consumable | $1.99 | 2_000_000 | `ios` |
| `unlock.mac` | non-consumable | $3.99 | 2_000_000 | `macos` |
| `unlock.bundle` | non-consumable | $4.99 | 5_000_000 | `ios`,`macos`,`bundle` |
| `upgrade.ios_to_bundle` | non-consumable | $3.00 | 5_000_000 | `ios`,`macos`,`bundle`; **requires** a verified, unrevoked `unlock.ios` on the same account |
| `upgrade.mac_to_bundle` | non-consumable | $0.99 | 5_000_000 | same; requires a verified, unrevoked `unlock.mac` on the same account. Owner-confirmed 2026-11-01. `ENABLE_MAC_UPGRADE` (default `"true"`) can switch it off. |

Non-consumables sync across platforms under universal purchase. That's why `unlock.ios` grants only the `ios` entitlement; the app honours it only on iOS and iPadOS.

- `POST /v1/storekit/transactions {"signed_transaction": "<JWS>"}`:
  1. Verify the JWS. The algorithm must be ES256. Check the `x5c` chain: the leaf must be signed by the intermediate, the intermediate by a trusted root, every certificate must be within its validity at `signedDate`, the leaf must carry OID `1.2.840.113635.100.6.11.1` and the intermediate OID `1.2.840.113635.100.6.2.1`. Then verify the signature with the leaf key. The trusted root is Apple Root CA - G3, embedded as PEM; tests inject their own root.
  2. Check that `bundleId` equals `BUNDLE_ID` and that `productId` is known (and enabled). `environment` is `Production`, or `Sandbox`/`Xcode` only when `ACCEPT_SANDBOX` is `"true"`.
  3. Binding: if `appAccountToken` is present and isn't the caller's `account_id`, return `403 ACCOUNT_MISMATCH`. If `originalTransactionId` is already bound to another account, return `409 BOUND_TO_OTHER_ACCOUNT`. There is no automatic transfer in v1.
  4. Record the transaction keyed by `transactionId`, unique. If it's already recorded, return `status:"already_recorded"` with **no new credit** (this covers restore and replay).
  5. If it has `revocationDate`, record it and return `status:"revoked"`, with no grant.
  6. For upgrades without their prerequisite, return `status:"pending_prerequisite"` with no grant. The grant happens automatically when the prerequisite is later recorded.
  7. Otherwise grant credit atomically: a ledger insert with `idempotency_key = "grant:" + transactionId` plus the balance increment in one D1 batch, into the balance for the transaction's environment (`production` or `sandbox`). Return `status:"granted"`.
  - Response: `{"transaction_id","product_id","environment","status","credit_granted_micros","balances","entitlements"}`.
- `POST /v1/storekit/notifications {"signedPayload": "<JWS>"}` (App Store Server Notifications V2, no auth). Verify it the same way, including the nested `signedTransactionInfo`. Then:
  - `REFUND` and `REVOKE`: set `revoked_at` and remove the entitlement. Claw back `min(credit_granted, current balance)` with idempotency key `refund:<transactionId>`; the shortfall is recorded on the row.
  - `REFUND_REVERSED`: clear the revocation and restore the clawed-back amount, with key `refund_reversed:<transactionId>`.
  - Unknown types return `200` and are ignored. Return 200 only after a successful commit.
- Entitlements are derived from unrevoked recorded transactions, never stored as booleans.

## Rendering and assist

Managed rendering spends the account's production balance and the owner's server-held `OPENAI_MANAGED_KEY`. It is **off** unless `MANAGED_RENDER_ENABLED == "true"` and the key is set; `GET /v1/me` reports the reason when it's off. Sandbox balances are spendable only when `ALLOW_SANDBOX_SPEND == "true"`, which is for bounded owner QA.

- `GET /v1/render/models`: returns `{"providers":[{"provider":"managed"|"openai"|"custom","models":[{"id","sizes":[…],"qualities":[…],"price_micros":{"<size>|<quality>":micros}|null}]}]}`. Prices come only for `managed`, from the `MANAGED_PRICE_TABLE` var (JSON). BYOK is billed by the provider and its prices show as null.
- `POST /v1/render/quotes {"provider","model","size","quality"}`: returns `{"quote_id","provider","model","size","quality","debit_micros","funding":"balance"|"sponsor_window"|"provider","expires_at"}`. The quote is valid for 10 minutes and is single use.
  - For `managed`, `debit_micros` comes from the price table, and the quote checks the balance and the monthly cap.
  - An active sponsor window with enough remaining credit funds a managed render before the customer balance.
  - BYOK quotes have `debit_micros: 0` and `funding: "provider"`.
- `POST /v1/render/jobs`. Body: `{"quote_id","idempotency_key"(uuid),"photo_upload_consent":true,"prompt":string(≤8000),"layout_image_png_base64":string,"source_image_base64"?:string,"source_media_type"?:"image/jpeg"|"image/png"}`.
  - `photo_upload_consent` must be literally `true` whenever a source image is sent; otherwise `400 CONSENT_REQUIRED`.
  - The debit is atomic. One D1 batch:
    - consumes the quote (`used_at IS NULL`);
    - inserts the job with a unique `(account_id, idempotency_key)`;
    - inserts a ledger debit keyed `debit:<job_id>`;
    - decrements the balance, guarded by `micros >= debit` and by the monthly cap.
  - If any guard fails, nothing changes and the response is `402 INSUFFICIENT_CREDIT`, `402 MONTHLY_CAP_REACHED` or `409 QUOTE_USED`.
  - Next comes the provider call. On provider failure a compensating ledger credit `refund:<job_id>` restores the debit, and the response is `502 PROVIDER_FAILED` with `refunded: true`.
  - A repeated `idempotency_key` returns the stored job status and never debits twice. Images aren't stored server-side; only job metadata is.
  - Response: `{"job_id","status":"succeeded","image_base64","media_type","debit_micros","balances","provider","model","label":"AI concept: cloud rendering, not a measured plan"}`.
- `POST /v1/assist`. Body: `{"provider":"anthropic"|"openai"|"custom","task":"critique"|"plant_ideas"|"describe","layout_brief":string(≤16000),"question"?:string(≤2000)}`. This is text only and BYOK only, with no debit. Anthropic uses `@anthropic-ai/sdk` with the customer key, model `ANTHROPIC_ASSIST_MODEL` (default `claude-opus-5-5`), `output_config.effort: "low"`, and no sampling parameters. Returns `{"text","provider","model"}`.

## Sponsorship (approved inventory only)

There is no ad network, no targeting, and no endpoint that creates sponsors. The owner inserts approved sponsors with `wrangler d1 execute` after their own review; see `gateway/SPONSORS.md`.

- Tables enforce `category IN ('democratic_candidate','democratic_issue')`, a non-empty `paid_for_by`, `approved_by` and `approved_at`, and `budget_remaining_micros >= 0`.
- `GET /v1/sponsorship/offers` returns `{"offers":[]}` unless a sponsor is active and approved with remaining budget. Each offer is `{"offer_id","sponsor_name","category","paid_for_by","disclosure","why_shown":"Shown to anyone whose included credit has run out. Not based on your photos, location or activity.","report_url","windows":[{"minutes":30|120|240|480|720|1440,"credit_cap_micros"}]}`.
- `POST /v1/sponsorship/windows {"offer_id","minutes"}` → `{"window_id","expires_at","credit_cap_micros","remaining_micros"}`.
  - It's allowed only when the customer's production balance is below the cheapest managed render price.
  - One active window per account.
  - The sponsor budget decrements by the cap atomically.
  - Unused cap returns to the sponsor budget lazily when the window expires.
- `POST /v1/sponsorship/report {"offer_id","reason"}` records a report.
- `POST /v1/sponsorship/dismiss {"offer_id"}` hides that offer for this account for 30 days.

## Configuration

- **Vars:** `BUNDLE_ID`, `ACCEPT_SANDBOX`, `MANAGED_RENDER_ENABLED`, `ALLOW_SANDBOX_SPEND`, `MANAGED_PRICE_TABLE`, `IMAGE_MODELS` (JSON list of allowed image model ids), `ANTHROPIC_ASSIST_MODEL`, `ENABLE_MAC_UPGRADE`, `KEK_CURRENT_VERSION`.
- **Secrets:** `KEK_1` (and later versions), `ADMIN_TOKEN` (optional), `OPENAI_MANAGED_KEY` (optional).
- No secret has a default; a missing `KEK_<current>` makes key routes return `503 CUSTODY_UNAVAILABLE`.
