# Privacy declarations for release

The app includes `apple/HomeGardenStudio/PrivacyInfo.xcprivacy`. Its baseline declares account-linked functionality data: user ID, purchase history, photos/videos, other user content, product interaction, other data and diagnostic data. It declares no cross-app tracking. Encryption and a random account ID do not make retained data unlinked.

The required-reason declaration is `NSPrivacyAccessedAPICategoryFileTimestamp / C617.1`: recovery storage uses `fstat` to validate the size and type of files inside the app's own container. Do not add unrelated categories without source or binary evidence. See Apple's [API categories and reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) and [manifest guidance](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files).

Before submission, inspect the final device/Mac archives, verify the manifest is bundled, generate the Xcode privacy report and reconcile App Store Connect answers with actual provider and hosting retention. The manifest is source configuration, not proof that Apple accepted those answers. Follow [Apple's data collection definitions](https://developer.apple.com/app-store/app-privacy-details/).

The baseline assumes sponsored inventory is unavailable. Before enabling funded advertisements, declare advertising data and third-party-advertising purposes for the account and interaction data used by those features, update the policy and App Store disclosures, and verify the deployed funding and selection rules. No ad network, behavior-based political targeting or invented sponsorship is permitted.

Keep request traces and invocation logs disabled in the deployment. The pinned Wrangler version supports those settings but does not expose the newer query-redaction field; deployments using the Cloudflare API also enable query-string redaction. Application events must remain fixed/redacted and must not contain credentials, prompts, images or response bodies. Check actual hosting settings and retention separately from this source file.
