# Apple-only edition

Home Garden Studio Apple is a separate native development build for Mac, iPhone and iPad. It uses the same Rust planning engine and portable `.hgsplan` documents as the standard app, with Apple frameworks providing its AI features.

The editor supports photo and file imports, deliberate page-link imports, drag-and-drop placement, dimensions, undo/redo, 2D plans, isometric views and RealityKit 3D. Documents retain imported originals and saved concept images. Local editing and geometric previews do not need an AI model or rendering balance.

The assistant uses Apple's on-device Foundation Models when the device, language and settings support them. Vision recognizes text and offers image-label guesses on the device. These suggestions cannot verify a plant species, establish measured coordinates from an unregistered photo or certify a layout.

Image Playground creates optional visual concepts using Apple image styles. The app excludes the external-provider style. You choose whether to include an imported photo, review Apple's generation sheet, and accept an image before it is saved with the plan. The generated image is inspiration; measured layout geometry remains authoritative. Supported styles, availability and limits depend on Apple's system service. The build does not promise a photorealistic or dimensionally exact result.

Apple-only does not mean every operation is offline. Apple may process image requests using Private Cloud Compute and manages its own usage limits. Explicit page-link imports contact the chosen website. There is no HomeGardenStudio cloud account, external AI key, cloud-credit purchase or advertising in this edition. If Apple AI is unavailable, the editor still works; no other provider takes over. See [Apple's Foundation Models framework](https://developer.apple.com/documentation/foundationmodels) and [Image Playground overview](https://developer.apple.com/videos/play/wwdc2026/375/).

## Build and verify

Use the repository's documented Rust, Xcode and XcodeGen prerequisites. From the repository root:

```sh
bash scripts/apple-verify.sh apple-only
```

This builds the shared core, generates the Xcode project, runs the Apple-only Mac tests, compiles for the iOS Simulator, and checks actual compiler inputs and both built bundles for excluded cloud components. It uses one build job at a time. The Mac tests launch the application as their test host; this is not an interactive editor walkthrough. The script does not boot an iOS Simulator, call an AI provider or upload a build.

The Xcode scheme is `HomeGardenStudioApple`. Its application identifier is `com.ashleyraiteri.homegardenstudio.appleonly`, so it can coexist with the standard app. Local build products are under `apple/build/DerivedData/Build/Products/`; the Mac product is `Debug/HomeGardenStudioApple.app`. A simulator build cannot be installed on a physical iPhone.

The development edition has full local editing without a purchase flow. This is not a new App Store price offer. App Store pricing, signing, real-device Apple Intelligence acceptance and distribution must be verified before a release. Existing standard-edition purchases and the 90-day credit promotion are separate.

## Privacy

This edition has no app-managed analytics, tracking, account identifiers, provider credentials or cloud-upload backend. Apple AI is invoked only through Apple frameworks. A selected reference photo or layout is provided to Apple's image-generation interface after the app explains that Apple handles processing. Apple governs that service's processing and limits. Documents saved in a cloud-synced location follow the storage service you chose.

The Apple-only target has its own privacy manifest and no shared-account keychain entitlement. File metadata is read to validate files in the app container or files you select. A final signed-archive privacy report and real-device checks are release requirements, not claims established by an unsigned local build.
