# TestFlight release preparation

The release driver is implemented and covered by synthetic command-boundary tests. This is preparation evidence: no successful signing, upload, processing, tester availability or installed-device QA is established by these tests. Run the real flow only when the release owner has authorized it, the Apple agreement and account prerequisites are resolved, and the native build slot is available. The script does not accept agreements, invite or create testers, submit external beta review or submit an App Store review.

## Select the outcome explicitly

Both modes require a clean Git tree, the numeric `HGS_APP_ID` belonging to HomeGardenStudio, an explicit `HGS_VERSION` such as `1.0.0`, and both `HGS_PRODUCTION_GATEWAY_URL` and `HGS_SANDBOX_GATEWAY_URL`. Supply the two owner-selected deployment origins through the release process environment; no deployment URL is configured by this document. The app readback must have bundle identifier `com.ashleyraiteri.homegardenstudio`; signing team and export profiles are fixed in the release configuration. Use the existing authorized ASC authentication. No credentials belong in project files or command-line arguments.

Gateway origins must be explicit lowercase ASCII HTTPS origins without credentials, a non-root path, query, fragment, whitespace, control characters or unresolved build-setting/template placeholders. The native client's optional root slash and explicit default `:443` are normalized away; the resulting production and sandbox origins must differ. Host syntax is validated without DNS or HTTP access. This establishes address configuration only, not gateway deployment health, environment identity or provider readiness. Verify those separately before release. Neither origin can be omitted for an upload-only release.

Upload and verify processing without distributing, after supplying both gateway environment variables:

```sh
: "${HGS_PRODUCTION_GATEWAY_URL:?Set the verified production gateway origin}"
: "${HGS_SANDBOX_GATEWAY_URL:?Set the verified sandbox gateway origin}"
export HGS_PRODUCTION_GATEWAY_URL HGS_SANDBOX_GATEWAY_URL
HGS_APP_ID=1234567890 HGS_VERSION=1.0.0 \
  bash scripts/release/testflight.sh ios upload-only
```

The numeric app ID above is a placeholder, not a configured app. For internal distribution, use the existing group's UUID in `HGS_GROUP` and the intended existing tester's UUID in `HGS_TESTER_ID`, then run:

```sh
bash scripts/release/testflight.sh ios internal
```

Use `macos` for the Mac archive. Internal mode requires exactly one ID for each resource; names and comma-separated groups are rejected. The group must read back as internal, belong to the selected app, and already contain the intended tester with `ACCEPTED` or `INSTALLED` state. The latter can describe a prior build: it never establishes installation of the current release. Upload-only mode rejects group/tester configuration so its outcome cannot be confused with distribution.

## Gates and retained evidence

Gateway configuration is validated before any subprocess, remote request or release-directory creation. Configuration, clean-source identity, remote app/group/tester identity and the build number are checked before any build. The next number comes from `asc builds next-build-number --app … --platform …`, considering expired/processed builds and in-flight uploads across marketing versions. This conservative choice also avoids reuse across Mac versions. Optional `HGS_BUILD_NUMBER` must be at least that returned number. The local format permits a positive first component of up to four digits and up to two additional components of up to two digits; unsupported returned formats stop for review. There is no timestamp fallback. Numbers are checked again immediately before upload; this reduces collisions but is not an ASC-side reservation. Keep one release owner per app/platform.

The runner passes `DISKCLEANER_TUI=0` to child processes only; it does not change the parent or system environment or launch a display. `diskcleaner check` must succeed, then `scripts/verify.sh full` must pass all required components. The full native verifier builds the core XCFramework and checks Mac and simulator builds/tests. Dirty source or a changed commit after verification or before upload stops the release. There is no skip-verification option. Xcode archive metadata must match the selected bundle, signing team, version and build; the contained app must declare the expected iPhoneOS or MacOSX platform. The archive command passes both canonical gateway origins as explicit Xcode build settings. Before export, the contained app’s `HGSProductionGatewayURL` and `HGSSandboxGatewayURL` plist values must exactly equal those selected origins; missing, substituted, swapped or stale values stop the run. Archive builds use Xcode `-jobs 1` and Swift `-driver-batch-count 1` to bound compilation concurrency. Export must produce exactly one regular IPA or PKG.

Every attempt gets a unique private directory under `.coordination/releases/<platform>/<version>/<build>/<attempt>/`. It retains the archive, export, DerivedData and JSON evidence. Nothing is removed from an earlier attempt. Large native artifacts should be included in the release owner's disk-space handoff and retired only through the workspace's authorized storage workflow.

`release.json` records the source commit, bundle/team/app identity, selected version/build/platform, intended audience, selected nonsecret production/sandbox gateway origins, archive/export paths, artifact SHA-256 and the last observed phase. `upload-receipt.json` is an allowlisted, redacted projection containing the returned build UUID and a SHA-256 of the parsed response; arbitrary upstream fields, URLs, headers and tester personal details are not saved. Command output and failures are not echoed. No raw receipt is retained.

Upload uses `--wait --checksum --output json`. A missing or malformed `buildId` stops the flow. `processed-build.json` is written only after querying that exact ID and verifying `VALID`, explicitly unexpired, the correct app, platform, marketing version and build number. Upload-only mode ends there and makes no availability claim.

Internal mode rechecks the audience immediately before assigning the exact returned build ID to the single verified group. It then reads back the group's build list, the intended tester's membership/readiness and the build's group relationship and `IN_BETA_TESTING` state. Only these matching results produce `availability.json` and `internal_available`. Installation, launch, use, visual QA and receipt by the tester remain separate evidence.

## Failures and recovery

Unknown or incomplete JSON schemas, unfinished pagination, identity mismatches and failed checks stop the run. No group is created and no tester is invited as a fallback. The script does not replay an upload automatically. A failed or timed-out upload may have completed remotely: preserve its archive, checksum and evidence, then reconcile ASC using the recorded app/platform/version/build before deciding what to do next. A prior `upload_started` attempt without a confirmed outcome blocks another release for that app/platform.

Recovery is a release-owner procedure, not an automatic retry mode. After read-only ASC reconciliation, retain a separate dated reconciliation record beside the attempt, including the exact remote build ID and observed outcome (or evidence that no upload was accepted). Update the attempt's phase to `reconciled_uploaded` or `reconciled_not_uploaded` only when that evidence establishes the outcome. For an accepted upload, continue readback/distribution of the existing build through the authorized ASC workflow; do not upload the same artifact again merely because the local call lost its response. No recovery edit alone proves tester availability.

## Local verification

Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_release.py'`. The fixtures mock Git, ASC, Xcode and diskcleaner; they exercise missing/malformed/equal gateway origins, canonicalization, exact build-setting propagation, iOS/Mac archive gateway mismatches, child-only no-display environment, invalid configuration, source changes, build-number races, internal audience checks, archive identity, unknown receipt schemas, exact-build processing, post-assignment availability, redaction and artifact retention. They perform no archive, network access, account mutation or upload. Shell syntax and export plists are checked in that suite. Real signing and ASC response compatibility remain release prerequisites.
