# HomeGardenStudio engineering

Read PRODUCT.md before implementation. This is a public native-app repository. Do not copy a private repository wholesale, inherit its Git history, or publish home photos, addresses, GIS records, production configuration or credentials.

Keep the Rust engine independent of the Apple UI. Prefer native SwiftUI, RealityKit and appropriate Apple frameworks over a web wrapper. Verify APIs against the selected Xcode SDK. Keep platform adapters, billing and secret custody testable and narrowly scoped.

Use the installed HaiKrew/crew-overseer workflow for bounded parallel implementation and independent review. One owner per file group and build directory. Run required checks and inspect actual results before reporting completion.

The implementation owner is the assigned Claude crew. The separate Codex monitor reviews evidence and writes private coordination reports; it does not race source edits. The parent Codex session owns the separate private garden editor and must not be displaced.

Private launch briefs, ownership, status and reports are under `.coordination/`, which is Git-ignored. Read the role-specific brief there. Commit only deliberately selected, audited public files. Never add `.coordination`, customer data, local auth profiles, generated signing assets or environment secrets.

Use secure default configurations. Server-side balances and verified entitlements are authoritative. Do not claim sponsorship or provider integrations are live until verified. Preserve the distinction between implementation, tests, public source, signed builds, upload, processing, TestFlight availability, review readiness and approval.

Do not bypass approval gates or change unrelated deployments. Shared global AWS, diskcleaner, MacBook Minion and handoff protocols still apply. Stop promptly on an explicit user stop request.
