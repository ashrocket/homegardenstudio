---
title: HomeGardenStudio privacy policy
---

# Privacy policy

**Draft for the first release.** HomeGardenStudio is in development; this document describes the intended data handling for the native iPhone, iPad and Mac apps and their optional gateway service. These statements must be checked against the final implementation before App Store submission.

## Your plans stay on your device

Plans, imported photos, product links and local previews live in plan files you save, on your device or in your own iCloud Drive. Planning, the plan view, the isometric view and the 3D view all run on your device. We don't receive your plans unless you use a cloud feature described below.

## What the optional cloud features send

Cloud features are off until you use them.

- **Account.** The first time you buy an unlock, save a provider key or request a cloud rendering, the app creates an anonymous account. It has a random ID and a secret, which the app keeps in your iCloud Keychain. We store a one-way hash of the secret. We don't ask for your name, email address or Apple ID.
- **Purchases.** When you buy an unlock, the app sends Apple's signed transaction to the gateway so we can confirm it and add the included rendering credit once. We keep the transaction ID, product, date, store environment and any refund or revocation status.
- **Rendering credit.** We keep a ledger of credits and debits for your account, and an optional monthly spending cap you set.
- **Your provider keys.** If you add your own OpenAI, Anthropic or compatible-provider key, the gateway stores it encrypted, bound to your account and that provider. No feature shows it back to you or to anyone else. You can delete it at any time.
- **Cloud renderings.** A rendering sends your layout drawing and text description, and any selected source photo, to the provider you chose. Explicit upload consent covers both separate photos and photos embedded in the layout drawing. The provider is OpenAI for managed credit, or the service you deliberately selected for your own key. We keep the job record, including provider, model, debit and result status. To recover interrupted downloads, the planned gateway makes encrypted generated images available only to your account for seven days. After access expires, encrypted image data is removed on access or during scheduled cleanup, which runs every ten minutes. The app acknowledges delivery only after saving the result. Expired undelivered managed results are refunded once; your own provider's charges follow its terms. Provider handling of uploaded inputs is governed by that provider's terms.
- **Planning help with your own key.** Text questions about your plan go to the provider you choose, with your key. Apple Intelligence features run on your device.

## What we don't do

No advertising identifiers, no tracking across apps or websites, no third-party analytics and no sale of data. Sponsored offers, when any exist, are shown to anyone whose included credit has run out. They are never chosen from your photos, location, plans or activity.

## Deleting your data

The planned Delete Account action revokes the account's access secret and removes stored provider keys and retained rendering results. It closes sponsored usage and resolves pending credit reservations. Minimal transaction and ledger records remain for refunds and store accounting; these financial identifiers are still data associated with the account.

Plan documents and exported originals can live separately from the app in Files, Finder or iCloud Drive. Delete those documents and any exports from their saved locations when you want to remove them. Uninstalling the app does not necessarily delete independent files, iCloud documents, backups or provider-held data.

## Contact

Questions or requests: open an issue at https://github.com/ashrocket/homegardenstudio/issues.
