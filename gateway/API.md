# HomeGardenStudio gateway API v1

The isolated Cloudflare Worker uses D1 for account metadata, encrypted provider custody, signed purchase state, credit, sponsorship and encrypted render recovery. All monetary values are safe integer micro-USD (1 USD = 1,000,000). No resource or product is created by this source. Managed rendering is disabled by default.

Errors are JSON: `{"error":{"code":"…","message":"…"}}`. Successful responses use `Cache-Control: no-store`. JSON bodies are limited to 64 KiB, or 12 MiB for render quotes/jobs, including chunked bodies. Responses and logs never disclose stored provider secrets. All account routes use `Authorization: Bearer hgs_…`.

## Accounts

- `POST /v1/accounts` → `201 {"account_id":"UUID","secret":"hgs_…"}`. The secret is generated with 32 random bytes; only its SHA-256 digest is stored. Creation is limited to five per trusted Cloudflare client IP per hour. A direct-origin deployment must not trust caller-supplied `cf-connecting-ip`.
- `GET /v1/me` → account ID, `balances:{production,sandbox}`, `entitlements:{ios,macos,bundle}`, `entitlement_environment`, `monthly_cap_micros`, `month_spent_micros`, `managed_render:{available,reason}`, `sponsorship_available`, `keys`, `credit_products:[{product_id,credit_micros,offer_starts_at,offer_ends_at,credit_expires:false}]`, `budget_adds_credit:false`.
- `PUT /v1/me/budget {"monthly_cap_micros":null|integer}` accepts 0–500,000,000. This is a hard UTC calendar-month spending ceiling against prepaid balance. Raising a ceiling never adds money. Lowering it below already-spent funds prevents further spending. Refunds release spending in the original job's month, including after a month boundary. Sponsor and BYOK spending do not consume this customer ceiling.
- `POST /v1/me/rotate-secret` replaces the bearer and returns `{account_id,secret}`. Save the new secret in synchronized Keychain before removing the old local value; other devices need the replacement. Lost-secret recovery is not available through transaction IDs, receipts, or Apple account guesses. Preserve the original account's Keychain entry for purchase restores.
- `DELETE /v1/me` revokes the secret, deletes keys and retained result parts, invalidates outstanding quotes, refunds unfinished/unacknowledged work and reclaims unused sponsor credit. Minimal financial rows and signed-state evidence remain for refund handling. Account deletion does not cancel Apple purchases. Completion and account writes are guarded against concurrent deletion. A hash-only deletion receipt permits the same bearer to retry only this DELETE endpoint after a lost response or interrupted cleanup; it grants no other API access. The receipt expires 30 days after cleanup completes and is removed by scheduled maintenance. Pending cleanup remains retryable until completed.

`ENTITLEMENT_ENVIRONMENT` is a server deployment setting, default `production`. A separate QA deployment may use `sandbox`; callers cannot select it. Production and sandbox balances, grants and entitlement derivation remain separate. Xcode-local receipts are rejected. Sandbox spend additionally requires `ALLOW_SANDBOX_SPEND=true`.

## Provider custody and discovery

Providers: `openai`, `anthropic`, `custom`.

- `PUT /v1/keys/:provider {"secret":"…","confirmed_provider":"openai|anthropic|custom","label":"optional","endpoint":"custom only"}` requires explicit provider confirmation. OpenAI credentials must start `sk-` and exclude `sk-ant-`; Anthropic requires `sk-ant-`. Secrets are 20–400 printable non-space ASCII characters. Custom endpoints are chosen explicitly.
- Response metadata: `{provider,label,fingerprint,endpoint_host,created_at,updated_at}`; timestamps here are ISO 8601. No plaintext read-back route exists.
- `DELETE /v1/keys/:provider` returns 204 and is idempotent.
- `POST /v1/keys/:provider/test` makes model discovery only, never paid generation. Response: `{ok,status,capabilities:{image_generation:false,text:false},discovery:"available"|"invalid_response",generation_verified:false,advertised_image_models?:[],message}`. A valid model list does not establish generation permission, quota, billing capacity, or actual availability. HTML/malformed JSON never counts as success. Anthropic is text-only.
- `POST /v1/admin/rotate-keys` requires the optional `ADMIN_TOKEN`; otherwise the route is absent. The result counts actual changed rows, and compare-and-set preserves concurrent updates/deletion.

Keys use AES-256-GCM, fresh 12-byte IVs and per-account HKDF-SHA256 derivation from the server-held 32-byte `KEK_<n>` secret. AAD includes account, record purpose/provider and KEK version. Result chunks use distinct `result:<job>:<part>` purposes. Ciphertext cannot be moved between tenants or purposes. Keep older KEKs until all live keys and retained results using them have expired or been migrated. Rotation changes key ciphertext and invalidates outstanding quotes conservatively.

All outbound calls pin the selected host, refuse redirects and use deadlines. Custom URLs must be HTTPS/default port, without userinfo, query or fragment; IP literals, ambiguous numeric addresses, provider lookalikes, local/internal suffixes and single-label names are rejected. **Public DNS destination enforcement relies on Cloudflare global fetch with `global_fetch_strictly_public`.** See the [runtime flag documentation](https://developers.cloudflare.com/workers/configuration/compatibility-flags/#global-fetch-strictly-public). No VPC, service binding, privileged origin fetch or user-supplied fetch adapter may replace this path. Local injected test adapters do not prove DNS/rebinding or same-zone protection. Those require authorized runtime verification before production.

Provider response JSON is streamed into bounded buffers: 256 KiB for discovery/text; 8 MiB base64 plus small JSON overhead for images. Slow, chunked, dishonest-size and malformed bodies fail. Anthropic SDK responses pass through the same bounded reader, with SDK retries disabled. OpenAI-compatible image and text calls do not retry automatically.

## StoreKit purchases and credit

Full product IDs use prefix `com.ashleyraiteri.homegardenstudio.`:

| Suffix | Approved US price | Credit micros | Access |
| --- | --- | --- | --- |
| `unlock.ios` | $1.99 | 2,000,000 | iOS/iPadOS |
| `unlock.mac` | $3.99 | 2,000,000 | macOS |
| `unlock.bundle` | $4.99 | 5,000,000 | Both |
| `upgrade.ios_to_bundle` | $3.00 | 5,000,000 | Both; requires active iOS unlock |
| `upgrade.mac_to_bundle` | $0.99 | 5,000,000 | Both; requires active macOS unlock |

`ENABLE_MAC_UPGRADE=true` is the approved default. Prices are configured in App Store Connect and displayed from StoreKit, never charged by this gateway.

Additional usage is optional prepaid credit with no automatic renewal. The owner-approved promotion is **US$10 for US$15 of rendering credit**, using the consumable `com.ashleyraiteri.homegardenstudio.credit.usd15`. Its permanent receipt definition grants exactly `15_000_000` micro-USD for each distinct verified transaction. Purchased credit **never expires**; there is no balance/ledger expiry and no subscription. A monthly cap limits spending without buying credit. Future render prices may change, but every render still requires approval of its exact quote before charging.

Storefront availability is separate from receipt acceptance. Configure both `CREDIT_OFFER_START_UTC` and `CREDIT_OFFER_END_UTC` as UTC ISO-8601 timestamps (`YYYY-MM-DDTHH:mm:ssZ`, optionally with exactly three fractional-second digits). The interval must be exactly 90 × 24 hours. The catalog includes this SKU only when `start <= server_now < end`; missing, malformed, non-UTC, reversed or non-90-day settings return no credit offers. Both values default to empty; this source chooses no launch/activation date. Removing or changing those merchandising settings never changes a verified purchase's credit grant.

For each active offer, `offer_starts_at` and `offer_ends_at` are epoch milliseconds and `credit_expires` is explicitly `false`. Clients must show the offer deadline separately from the credit's nonexpiry, fetch the matching StoreKit product for its actual localized price, and refresh server eligibility immediately before initiating checkout. The owner must configure the US storefront price as US$10 in App Store Connect; the gateway does not fabricate a price or infer payment amount from a UI value.

**Release gate:** choose and record the UTC activation window only when the App Store product is ready. App Store availability must also end at the recorded deadline; hiding the app catalog cannot make a cached or already-started StoreKit purchase disappear. Coordinate and verify removal from sale through the authorized Apple release process. No StoreKit or App Store configuration is changed by this code. A genuine verified purchase, including a late transaction first submitted after the offer ended or an Apple availability race, is still honored. Restore, unfinished-transaction retry, pending-grant repair, refunds and idempotent replay remain independent of the offer window. Unknown product IDs remain rejected. Do not remove the permanent accepted SKU definition when the promotion ends. The former arbitrary `CREDIT_PRODUCTS` mapping is no longer used; remove that obsolete deployment variable when adopting this fixed approved SKU.

- `POST /v1/storekit/transactions {"signed_transaction":"JWS"}` verifies ES256, Apple certificate chain and marker extensions, bundle, environment and configured product. New purchases **must** contain the authenticated account UUID in signed `appAccountToken`; tokenless and mismatched claims are rejected. Original transaction binding is unique in storage. No automatic account transfer exists.
- Transactions are stored as durable pending records. An atomic eligibility check, ledger grant and balance update releases them once. A crash before release is repaired by replay, account refresh or scheduled maintenance. A prerequisite must be granted, unrevoked and in the **same StoreKit environment**. Pending upgrades confer neither access nor credit. Prerequisite revocation suspends dependent bundle entitlement; it does not reverse the separately paid upgrade's credit. Restoring the prerequisite restores access without another upgrade grant.
- Response: `{transaction_id,product_id,environment,status,credit_granted_micros,balances,entitlements}`. `credit_granted_micros` is the transaction's lifetime grant, not a newly credited delta. Replay can return `granted` with the same lifetime amount; it never grants again.
- `POST /v1/storekit/notifications {"signedPayload":"JWS"}` verifies outer and inner JWS and stores notification identity. `REFUND`, `REVOKE`, `REFUND_REVERSED` reconcile signed transaction state. Unknown notification types acknowledge with `handled:false`.
- Signed transaction `signedDate` orders state. Old evidence cannot override newer state. An equally signed contradictory state or notification/transaction disagreement returns 409 and requires fresh authoritative transaction evidence; arrival order is not treated as truth. Unknown-transaction revocation evidence survives until registration. Identity changes are rejected. Refunds claw back at most the currently available balance; the shortfall is recorded and reserves an equal amount from future spendable balance. A late render refund therefore cannot make revoked purchase credit spendable again. A reversal restores exactly that clawback, and a later valid revocation can claw it back again. Each accepted transition and its financial effect commit atomically.

## Quote, consent and render recovery

Get available model/size/quality options using `GET /v1/render/models`. Managed prices come only from validated `MANAGED_PRICE_TABLE`; BYOK prices are null and billing remains with the provider. Anthropic is not an image endpoint.

A quote includes the exact render inputs and requires consent **before submitting them to this gateway**. It does not call the provider. The input digest covers prompt, decoded layout/source image bytes, source media type and explicit consent. Only the digest is retained in the quote; input photos/prompts are not stored. Example (the native app supplies a real encoded layout):

```json
{
  "provider":"managed",
  "model":"gpt-image-2",
  "size":"1024x1024",
  "quality":"low",
  "photo_upload_consent":true,
  "prompt":"Render the approved garden layout",
  "layout_image_png_base64":"<PNG base64>",
  "source_image_base64":"<optional JPEG or PNG base64>",
  "source_media_type":"image/jpeg"
}
```

`POST /v1/render/quotes` returns `{quote_id,provider,model,size,quality,debit_micros,funding,expires_at,destination_host,provider_billing,input_digest}`. Timestamps for quotes/jobs/windows are integer Unix milliseconds. Funding is immutable: `balance`, `sponsor_window` or `provider`. A quote expires in ten minutes. Managed quotes prefer a funded active sponsor window over customer balance. A quote is a proposal; availability is checked again when accepting it.

`POST /v1/render/jobs` repeats **exactly** the prompt/image/consent fields above and adds `quote_id` and a stable UUID `idempotency_key`. Provider/model/size/quality come from the stored quote. The app persists the key before submitting and reuses it after transport errors. Changed inputs return `QUOTE_INPUT_CHANGED`; changed idempotent payloads return `IDEMPOTENCY_MISMATCH`; key or destination changes require a fresh quote and consent review.

Acceptance is one D1 transaction: assert tenant, current account, quote expiry/unused state, exact input and destination, then insert the unique quote/job/idempotency record, ledger debit, funding decrement and monthly spend. SQL assertions raise rather than relying on zero-row updates; CHECK and UNIQUE violations roll back every statement, following the [D1 batch transaction model](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch). Sponsor spending never changes customer balances. Concurrent funding/budget/quote changes return `409 QUOTE_OR_FUNDING_CHANGED`; quote-time insufficient credit/cap returns 402.

Only the transaction winner calls upstream. No retry redispatches. A failure or ambiguous upstream outcome refunds the gateway debit once; the operator absorbs any ambiguous managed provider charge. BYOK provider charges cannot be reversed by this gateway. A crashed pending job is refunded after ten minutes by retrieval or scheduled maintenance. The daily operator ceiling counts all accepted managed quotes, including failed/refunded attempts, and is not released by customer refunds. It is a conservative quoted-cost ceiling, **not** a guarantee about provider invoicing; real provider prices must be checked before enabling.

Successful response:

```json
{"job_id":"UUID","status":"succeeded","image_base64":"<PNG>","media_type":"image/png","debit_micros":100,"funding":"balance","provider":"managed","model":"gpt-image-2","label":"AI concept: cloud rendering, not a measured plan","result_expires_at":1794168000000,"acknowledged":false,"balances":{"production":900,"sandbox":0}}
```

`GET /v1/render/jobs/:id` and identical POST retries return the account's stored status/result. `pending` uses HTTP 202. A failed result returns `{status:"failed",error_code,refunded,provider_billing,…}`. Successful images are encrypted in bounded 256-KiB plaintext chunks, accessible for seven days and never shared across tenants; expired ciphertext is removed on first access or the next ten-minute maintenance sweep.

**After saving the image durably on the device**, call `POST /v1/render/jobs/:id/ack {}`. Acknowledgement preserves the debit when retention expires. An unacknowledged successful result that expires receives an explicit once-only refund; encrypted parts are deleted. After acknowledged retention expiry, metadata remains but `image_base64` is absent. Missing custody KEKs are an operational recovery failure, not permission to send the request upstream again.

`POST /v1/assist` accepts `{provider:"anthropic"|"openai"|"custom",task:"critique"|"plant_ideas"|"describe",layout_brief:"…",question:"optional"}`. It sends text only using the saved BYOK credential, uses no gateway credit, and returns `{text,provider,model,provider_billing:true}`. Anthropic uses its SDK and configured model with low effort; no text model is guessed for custom/OpenAI endpoints.

## Sponsorship

See [SPONSORS.md](SPONSORS.md). No inventory is seeded and no public route creates sponsors. Only owner-approved Democratic candidate/issue records with disclosure and real finite funding qualify. No photos, location, political inference, or behavioral audience selection is used.

- `GET /v1/sponsorship/offers` returns `{offers:[]}` when no active, funded, undismissed approved inventory exists. Offers include sponsor identity, category, paid-for-by disclosure, reason shown, report URL and funded window options.
- `POST /v1/sponsorship/windows {offer_id,minutes}` requires exhausted production credit (below the cheapest configured render), atomically reserves a finite cap, and enforces one unsettled window per account. Allowed minutes: 30, 120, 240, 480, 720, 1440.
- Response: `{window_id,expires_at,credit_cap_micros,remaining_micros}`.
- Job acceptance rechecks sponsor and offer approval and expiry, and debits exactly the quoted window. A later failure returns money to that window while unsettled or to the original sponsor if settled. Expiry reclamation is atomic and once-only; in-flight debits are excluded from reclaimed unused funds.
- `POST /v1/sponsorship/report {offer_id,reason}` records a 1–1000-character reason.
- `POST /v1/sponsorship/dismiss {offer_id}` hides an offer for 30 days.

## Configuration and release gates

Runtime vars: `BUNDLE_ID`, `ACCEPT_SANDBOX`, `ENTITLEMENT_ENVIRONMENT`, `MANAGED_RENDER_ENABLED`, `ALLOW_SANDBOX_SPEND`, `MANAGED_PRICE_TABLE`, `MANAGED_DAILY_LIMIT_MICROS`, `IMAGE_MODELS`, `ANTHROPIC_ASSIST_MODEL`, `OPENAI_ASSIST_MODEL`, `ENABLE_MAC_UPGRADE`, `CREDIT_OFFER_START_UTC`, `CREDIT_OFFER_END_UTC`, `KEK_CURRENT_VERSION`. Secrets: `KEK_<n>`, optional `ADMIN_TOKEN`, optional `OPENAI_MANAGED_KEY`. Missing key custody fails closed. Managed rendering requires explicit enablement, a key, prices, encrypted result custody and a positive daily operator ceiling. Cron maintenance runs every ten minutes. Maximum-size encrypted result batches require the [Workers Paid D1 query allowance](https://developers.cloudflare.com/d1/platform/limits/); deploy and verify that capacity before enabling paid rendering.

Deployment must separately verify D1 migrations, real Apple certificate validation fixtures and notification delivery, App Store product setup and account tokens, server-selected production/QA separation, Cloudflare strict public fetch and same-zone behavior, source privacy, provider billing/size/pricing compatibility, secrets rotation/retention and native durable acknowledgement. Local injected-network D1 tests establish no deployment, live provider availability, real purchase, TestFlight distribution or App Store acceptance.

Local tooling is pinned to project-local Wrangler 4.85.0; global tooling is not used. Run `npm ci`, `npm run types:check`, `npm run typecheck`, `npm test`, and `npm run package:check` before release. The final command packages locally with `--dry-run`; it does not create resources or deploy. Generated configuration bindings are in `worker-bindings.d.ts`; regenerate with `npm run types` after config changes. CLI flags must be checked against this pinned version (it does not support the newer `--profile` option).
