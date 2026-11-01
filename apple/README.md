# Native Apple workspace

The application is a SwiftUI document app for macOS 26 and iOS/iPadOS 26. The default workspace is a full canvas with collapsed secondary panels. A wide window can keep the feature library beside the map; compact windows use a sheet. The inspector offers keyboard and assistive-technology alternatives to direct manipulation. All local previews use the shared Rust geometry engine.

A `.hgsplan` package contains `project.json`, byte-exact files under `Originals/`, and `Renders/`. Imports never re-encode the original attachment. Packages verify stored attachment SHA-256 filenames and metadata sizes when reopened. Originals are retained when source references are removed so undo remains reversible. Current limits are 40 MB per photo/file, 2 MB per fetched URL response, and 256 MB of combined originals and renders per plan. JSON export carries metadata and layout only; portable plan export carries attachments too. Missing attachments from metadata-only JSON imports are reported when a backdrop or calibration needs them.

Photos and two-point scale calibration do not establish measured positions. Field measurement records a deliberate user assertion about current values; geometry changes invalidate that evidence in the engine. Local 3D uses simplified parts, including the engine's bounding-box approximation for site structures. It is not photorealistic output or a survey.

The free plan blocks new feature additions above twelve. Existing larger plans remain openable, editable and exportable. `Entitlements` is injectable; the phase-A build uses the free implementation. Cloud rendering, provider keys and StoreKit are not implemented or presented as working controls here.

## Build and focused tests

Install Xcode 26, XcodeGen 2.45.4 or later, and the Rust targets `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios`, and `aarch64-apple-ios-sim`. The Simulator target is arm64; Intel Simulator is excluded because the shared XCFramework has no Intel Simulator slice. Run `scripts/apple-verify.sh` from the repository root after reserving the shared native build slot. The script checks disk pressure, builds the Rust XCFramework with one Cargo job, generates the Xcode project, runs the macOS build and unit tests, and builds for iOS Simulator with one Xcode job. It fails on any failed stage. It does not archive, sign for distribution, upload, or alter signing accounts.

Generated projects, frameworks and local build outputs are ignored. The project configuration retains the release bundle and team identifiers; verification overrides use local ad-hoc/unsigned signing.

Unit tests cover bridge commands and undo/redo, repeated C-returned strings, source serialization, portable persistence and attachment corruption, length parsing, free-plan limits and retained access, replacement undo, URL metadata parsing, and rejection of photo-only measurement evidence.

## Interaction verification still required

A successful build is only a compilation gate. Exercise direct move, corner resize, rotation, cancellation, library drag/drop, zoom, keyboard nudge/delete/duplicate, field commits, document save/reopen, photo/file imports, and previews on Mac, iPhone and iPad. Check narrow windows, large type, light/dark contrast, VoiceOver, keyboard focus and reduced-effects settings. The canvas uses no decorative animation or transparent material that requires a motion-dependent fallback. Run the design skill's static audit and retain actual native runtime evidence before making a visual-quality claim.
