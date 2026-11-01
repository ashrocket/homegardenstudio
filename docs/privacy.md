---
title: HomeGardenStudio privacy policy
---

# Privacy policy

**Draft for the first release.** HomeGardenStudio is in development; this document describes the intended data handling for the native iPhone, iPad and Mac apps and their optional gateway service. These statements must be checked against the final implementation before App Store submission.

## Your plans stay on your device

Plans, imported photos, product links and local previews live in plan files you save, on your device or in your own iCloud Drive. Planning, the plan view, the isometric view and the 3D view all run on your device. We don't receive your plans unless you use a cloud feature described below.

Importing a product URL contacts that website directly to fetch its content. That website receives the request under its own privacy practices. The imported original stays in your plan and is not automatically sent to our account service.

## What the optional cloud features send

Cloud features are off until you use them.

- **Account.** You choose Create cloud account before using purchases or cloud features. The account has a random ID and a secret, which the app stores in synchronized Keychain. We store a one-way hash of the secret. Preserved account identities remain available for deliberate recovery; selecting one does not transfer purchases, credit or provider keys between accounts. We don't ask for your name, email address or Apple ID.
- **Purchases.** When you buy an unlock, the app sends Apple's signed transaction to the gateway so we can confirm it and add the included rendering credit once. We keep the transaction ID, product, date, store environment and any refund or revocation status.
- **Rendering credit.** We keep a ledger of credits and debits for your account, and an optional monthly spending cap you set.
- **Your provider keys.** If you add your own OpenAI, Anthropic or compatible-provider key, the gateway stores it encrypted, bound to your account and that provider. It also keeps your optional label, key fingerprint and selected endpoint. The gateway decrypts the key to make requests you authorize; this is not end-to-end encryption. No feature reads the key back to a client. You can delete it at any time.
- **Cloud renderings.** With your upload approval, the layout drawing, text prompt and any selected reference photo first go to the account service for a quote. This includes any photo embedded in the layout drawing. Only after you approve the quoted request does the service send it to your selected provider. The gateway retains input digests and quote/job metadata, including provider, model, debit, delivery and failure status, rather than plaintext request images or prompts. Generated images are encrypted and accessible only to your account for seven days; expired image data is removed on access or during the ten-minute cleanup. The app saves a result durably before acknowledging it. Expired undelivered managed results are refunded once; your own provider's charges follow its terms. Each provider's retention and use of uploaded content follow its own terms and account settings; we do not promise zero retention by a provider.
- **Planning help with your own key.** With your approval, the plan's text context and your question go to the provider you choose through the account service. This text request does not send photos. Apple Intelligence and image-label assistance run on your device when supported. If you choose a local model endpoint, you operate that server and control whether it forwards information elsewhere.

The app keeps the approved render request and received result in device recovery storage so an interrupted request can be resumed without starting a second paid generation. These recovery copies are separate from saved plan attachments and can be removed through the recovery controls.

The account service uses hashed network/account rate-limit buckets, counters and fixed error records to prevent abuse and recover failures. Hosting providers also process network requests. These records are used for service operation, not behavioral advertising. A random account ID still links purchases, provider settings and job records to the same account.

## What we don't do

No advertising identifiers, no tracking across apps or websites, no third-party analytics SDK and no sale of data. There is currently no sponsored inventory. If funded sponsorship becomes available, it will be optional and will not use your photos, location or inferred political views to select advertisements. The service records selected windows, dismissals and reports to fund the chosen allowance and honor your choices. Privacy declarations must be updated before that feature is enabled.

## Deleting your data

Delete cloud account revokes its access secret and removes stored provider keys, server image copies and that account's device recovery copies. It closes sponsored usage and resolves pending credit reservations. A one-way deletion receipt lets the app finish or confirm deletion after an interrupted connection. It allows only deletion retries, expires 30 days after cleanup finishes, and is removed during scheduled cleanup.

Deletion retains the account tombstone, transaction/ledger records and quote/job metadata for purchase accounting, refund handling and recovery records. Any existing sponsorship accounting, dismissal or report records also remain. These records are still associated with the random account ID; they do not include retained render image bytes or provider-key plaintext. The current service has no automatic removal schedule for this retained metadata. Rate-limit hashes are pruned opportunistically after their retention threshold, rather than on a guaranteed deletion deadline.

Plan documents and exported originals can live separately from the app in Files, Finder or iCloud Drive. Delete those documents and any exports from their saved locations when you want to remove them. Uninstalling the app does not necessarily delete independent files, iCloud documents, backups or provider-held data.

## Contact

Questions or requests: open an issue at https://github.com/ashrocket/homegardenstudio/issues.
