# Product contract

## Goal and release

Build a working native macOS and iOS/iPadOS app, publish its source in the public `ashrocket/homegardenstudio` repository, distribute working builds through TestFlight, and prepare complete App Store review submissions. TestFlight upload, processing, tester availability and App Store review readiness are separate milestones. The application is native, not a website or a web-view wrapper.

## Planning

Use Rust for the shared project, geometry, validation and layout engine. Use native Apple UI and graphics frameworks where they provide the best platform experience. Support photo/file and URL imports; direct drag-and-drop placement; editable dimensions, rotation and positions; undo/redo; local persistence; portable project export/import; full-screen workspace with tools reachable and secondary panels collapsed. Preserve originals and source provenance. An unregistered photo cannot establish measured plant, building or fence coordinates.

Provide 2D plan, isometric and actual 3D views. Make local views and cloud photorealistic renderings distinguishable. Rendering must retain the requested layout and source context, with uncertainty visible. Include configurable plants, ponds, contained fire-pit circles, pergolas, saunas, tool sheds and roofless L-shaped bin screens.

## AI and key custody

Use deterministic code and native/local inference first. Detect Apple Intelligence availability at runtime; support other local model adapters where feasible without pretending unavailable capabilities work. Do not download large model weights without an explicit user action.

Offer prepaid managed OpenAI rendering and bring-your-own-provider URL/key. Recognize OpenAI and Anthropic credentials with explicit provider confirmation before testing or transmitting them. Use provider-specific protocols and honest capability labels. Anthropic is not a direct image-generation endpoint. Custom compatible providers require deliberate endpoint selection. Never send a credential to a guessed host.

Store customer keys securely on Cloudflare: authenticated per-user custody, encryption at rest with a server-held encryption secret, tenant-bound authenticated encryption, rotation/deletion, redacted logs and no plaintext read-back endpoint. No provider key in public source, client bundles, project files, analytics or crash reports. A local model URL on the user's own machine is a separate adapter from a cloud proxy. Require explicit photo-upload consent for cloud inference.

## Approved prices and balances

- Free downloads, with useful and clearly labelled trial behavior, transparent upgrade terms and retained access to customer work.
- iOS unlock: US $1.99, including $2 of rendering credit.
- macOS unlock: US $3.99, including $2 of rendering credit.
- Both-platform bundle: US $4.99, including $5 of rendering credit.
- iOS-to-bundle upgrade: US $3.00, including $5 of rendering credit. Require verified ownership of the iOS unlock.
- Proposed fair macOS-to-bundle upgrade: US $1.00, crediting the solo price toward the bundle. Confirm its exact product configuration before public pricing claims; the owner explicitly confirmed only the iOS upgrade price.

Verify StoreKit purchases server-side, bind entitlements to the customer, and grant each qualifying transaction's credit exactly once. Restore must not mint credit again. Refunds/revocations must be handled. The owner clarified that solo purchases receive $2, while bundle or paid bundle upgrades receive $5. The earlier suggestion of 5/10 starter renders is superseded.

Do not promise that $2 buys 100 cloud images. Show the actual quoted debit before submitting a render. Local plan/3D previews do not consume cloud credit. Optional monthly usage budgets require a hard cap and no surprise overages; exact recurring product tiers remain to be finalized. Prefer prepaid optional spending and preserve purchased balances according to platform rules. Use Apple's applicable in-app purchase mechanisms, no hidden web checkout.

## Optional sponsorship

When included usage is exhausted, offer a deliberate choice between a paid usage budget, the customer's own provider, or available approved sponsorship. Do not force ads onto a paid editor. There must be no open ad network or unrestricted advertisers: only explicitly approved Democratic candidates and Democratic issue sponsorships. Do not infer political beliefs from customer photos, geography or usage, or build behavioral political targeting.

Sponsor-funded usage windows: 30 minutes, 2, 4, 8, 12 or 24 hours. Each window must have a finite funded credit cap as well as an expiry. No unlimited rendering promise. No sponsor funding or valid inventory means no ads and no invented subsidy. Clearly label ads, sponsor identity, why displayed, reporting and dismissal. No candidate endorsements, fabricated sponsors, commitments or purchases on the owner's behalf. Separate customer balances from sponsor budgets.

## Verification and privacy

Use synthetic demo projects and redistributable assets only in the public repository. Require focused Rust geometry, persistence and FFI tests; native builds and interaction QA on Mac and iOS; credential tenant-isolation and SSRF tests; transactional quota/idempotency tests; purchase restore/replay/refund tests; and release checks. Never treat a local build as proof of TestFlight distribution or App Store acceptance.
