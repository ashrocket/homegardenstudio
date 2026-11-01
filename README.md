# HomeGardenStudio

A native garden planner for macOS 26 and iOS/iPadOS 26, with a shared Rust layout engine and SwiftUI and RealityKit interfaces.

**In development.** Mac unit tests and iOS Simulator compilation pass. TestFlight distribution and App Store release are still pending. There is no released installer or download yet.

Import your photos and product links, arrange features at real dimensions, and explore a plan, an isometric drawing and a 3D view. Local editing and previews work without cloud rendering. Optional AI services can produce photorealistic concepts from your source photos and layout.

Save a portable `.hgsplan` document containing the layout, unchanged imported originals and attached concept images. The workspace keeps secondary panels collapsed, with tools available beside the canvas or in compact sheets. Free plans allow twelve new features; existing larger plans remain editable and exportable.

The optional account service supports verified App Store unlocks, prepaid credit, encrypted provider-key storage and interrupted-render recovery. Managed rendering is disabled until funding and provider pricing are configured. Apple on-device assistance checks runtime availability; an explicit loopback adapter supports compatible local text models. OpenAI and compatible providers can supply images, while Anthropic supplies text assistance. Real purchases and provider generation still require release verification.

## Build locally

Use Xcode 26 or later, XcodeGen 2.45.4 or later, Rust with Cargo, and a current Node.js LTS release. Install the Rust targets used by the native framework:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
npm ci --prefix gateway
bash scripts/verify.sh full
```

The full verifier checks publication rules, the Rust engine, the gateway and both Apple targets. It performs unsigned/ad-hoc local verification; it does not deploy or upload. Native builds run serially. On the shared development Mac, they use the installed diskcleaner guard; other Macs receive a free-space check.

For a focused change, use `bash scripts/verify.sh core`, `gateway`, `apple` or `privacy`. See the [native workspace guide](apple/README.md), [gateway contract](gateway/API.md) and [release procedure](docs/release.md). Account origins and signing configuration must be supplied deliberately for distribution; local editing works without cloud configuration.

## Project layout

| Directory | Responsibility |
| --- | --- |
| `core/` | Rust project model, geometry, provenance, history and C bridge |
| `apple/` | Native document editor, previews, imports, local AI and account UI |
| `gateway/` | Cloudflare account, key custody, purchase ledger and render recovery service |
| `scripts/` | Source checks, native builds and guarded release tooling |
| `docs/` | Support, privacy and release documentation |

The approved product and pricing requirements are in [PRODUCT.md](PRODUCT.md). Development and verification rules are in [AGENTS.md](AGENTS.md).

No personal property records, customer photographs, credentials or saved customer plans belong in this public repository.
