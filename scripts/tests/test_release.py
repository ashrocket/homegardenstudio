"""Release CLI boundaries use synthetic ASC/Xcode fixtures; no network or builds."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

RELEASE = Path(__file__).resolve().parents[1] / "release"
# Unique module name avoids collision with unittest discovery's own filenames.
sys.path.insert(0, str(RELEASE))
import guards
SPEC = importlib.util.spec_from_file_location("hgs_release_driver", RELEASE / "testflight.py")
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)
sys.path.pop(0)

APP = "1234567890"
GROUP = "11111111-1111-1111-1111-111111111111"
TESTER = "22222222-2222-2222-2222-222222222222"
BUILD = "33333333-3333-3333-3333-333333333333"
VERSION = "44444444-4444-4444-4444-444444444444"
DETAIL = "55555555-5555-5555-5555-555555555555"
COMMIT = "a" * 40
PRODUCTION = "https://production.example.com"
SANDBOX = "https://sandbox.example.com"


def item(kind, ident, **attrs):
    return {"type": kind, "id": ident, "attributes": attrs}


def relation(kind, ident):
    return {"data": {"type": kind, "id": ident}}


def config(mode="internal", platform="ios", **changes):
    env = {"HGS_APP_ID": APP, "HGS_VERSION": "1.0.0",
           "HGS_PRODUCTION_GATEWAY_URL": PRODUCTION, "HGS_SANDBOX_GATEWAY_URL": SANDBOX}
    if mode == "internal":
        env.update(HGS_GROUP=GROUP, HGS_TESTER_ID=TESTER)
    env.update(changes)
    return guards.Config.parse([platform, mode], env)


class FakeRunner:
    def __init__(self, root):
        self.root = root
        self.calls = []
        self.dirty = False
        self.assigned = False
        self.number = "7"
        self.mutate = lambda args, response: response
        self.fail = None
        self.omit_artifact = False
        self.artifact_count = 1
        self.archive_changes = {}
        self.archive_platform = "iPhoneOS"
        self.app_info_changes = {}

    def run(self, args, cwd):
        args = tuple(str(v) for v in args)
        self.calls.append(args)
        if self.fail and self.fail(args):
            raise guards.ReleaseError("Synthetic command failure")
        if args[:2] == ("git", "status"):
            return b" M changed\0" if self.dirty else b""
        if args[:2] == ("git", "rev-parse"):
            return COMMIT.encode()
        if args[0] == "xcodebuild":
            if "archive" in args:
                archive = Path(args[args.index("-archivePath") + 1])
                archive.mkdir()
                properties = {"CFBundleIdentifier": guards.BUNDLE, "CFBundleVersion": "7",
                              "CFBundleShortVersionString": "1.0.0", "Team": guards.TEAM,
                              "ApplicationPath": "Applications/HomeGardenStudio.app"}
                properties.update(self.archive_changes)
                (archive / "Info.plist").write_bytes(plistlib.dumps({"ApplicationProperties": properties}))
                app = archive / "Products/Applications/HomeGardenStudio.app"
                app.mkdir(parents=True)
                app_info = {"CFBundleSupportedPlatforms": [self.archive_platform],
                            "HGSProductionGatewayURL": PRODUCTION, "HGSSandboxGatewayURL": SANDBOX}
                app_info.update(self.app_info_changes)
                app_info = {k: v for k, v in app_info.items() if v is not None}
                if self.archive_platform == "MacOSX":
                    app = app / "Contents"
                    app.mkdir()
                (app / "Info.plist").write_bytes(plistlib.dumps(app_info))
            else:
                export = Path(args[args.index("-exportPath") + 1])
                export.mkdir()
                if not self.omit_artifact:
                    for n in range(self.artifact_count):
                        (export / ("Synthetic app " + str(n) + (".pkg" if self.archive_platform == "MacOSX" else ".ipa"))).write_bytes(b"synthetic artifact")
            return b""
        if args[0] != "asc":
            return b""
        op = args[1:]
        if op[:2] == ("apps", "view"):
            response = {"data": item("apps", APP, bundleId=guards.BUNDLE)}
        elif op[:3] == ("testflight", "groups", "view"):
            response = {"data": item("betaGroups", GROUP, isInternalGroup=True)}
        elif op[:4] == ("testflight", "groups", "app", "view"):
            response = {"data": item("apps", APP, bundleId=guards.BUNDLE)}
        elif op[:4] == ("testflight", "groups", "testers", "list"):
            response = {"data": [item("betaTesters", TESTER, state="ACCEPTED")], "links": {"next": None}}
        elif op[:4] == ("testflight", "groups", "builds", "list"):
            response = {"data": [item("builds", BUILD)]}
        elif op[:2] == ("builds", "next-build-number"):
            response = {"nextBuildNumber": self.number}
        elif op[:2] == ("builds", "upload"):
            response = {"buildId": BUILD, "presignedURL": "https://synthetic.invalid/private?capability=redact"}
        elif op[:2] == ("builds", "add-groups"):
            self.assigned = True
            response = {"ok": True}
        elif op[:2] == ("builds", "info"):
            build = item("builds", BUILD, processingState="VALID", expired=False, version="7")
            build["relationships"] = {"app": relation("apps", APP), "preReleaseVersion": relation("preReleaseVersions", VERSION),
                "buildBetaDetail": relation("buildBetaDetails", DETAIL),
                "betaGroups": {"data": [{"type": "betaGroups", "id": GROUP}] if self.assigned else []}}
            response = {"data": build, "included": [item("preReleaseVersions", VERSION, version="1.0.0", platform="MAC_OS" if self.archive_platform == "MacOSX" else "IOS"),
                       item("buildBetaDetails", DETAIL, internalBuildState="IN_BETA_TESTING" if self.assigned else "READY_FOR_BETA_TESTING")]}
        else:
            raise AssertionError("Unexpected synthetic CLI call")
        return json.dumps(self.mutate(args, copy.deepcopy(response))).encode()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hgs release fixture ")
        self.root = Path(self.temp.name)
        self.fake = FakeRunner(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def release(self, cfg=None):
        return driver.Release(self.root, cfg or config(), self.fake)

    def no_build(self):
        self.assertFalse(any(c[0] in ("xcodebuild", "xcodegen", "bash") for c in self.fake.calls))

    def no_upload(self):
        self.assertFalse(any(c[:3] == ("asc", "builds", "upload") for c in self.fake.calls))

    def test_configuration_rejected_before_any_command(self):
        for env in ({}, {"HGS_APP_ID": APP}, {"HGS_APP_ID": APP, "HGS_VERSION": "1.0.0"},
                    {"HGS_APP_ID": APP, "HGS_VERSION": "1.0.0", "HGS_GROUP": GROUP+","+GROUP, "HGS_TESTER_ID": TESTER}):
            with self.subTest(env=env), self.assertRaises(guards.ReleaseError):
                guards.Config.parse(["ios", "internal"], env)
        with self.assertRaises(guards.ReleaseError):
            config(HGS_BUILD_NUMBER="202611011245")
        with self.assertRaises(guards.ReleaseError):
            config("upload-only", HGS_GROUP=GROUP)
        self.assertEqual(self.fake.calls, [])

    def test_gateway_configuration_rejects_unsafe_values_before_any_command(self):
        invalid = [None, "", "http://production.example.com", "https://user:secret@production.example.com",
                   "https://production.example.com/path", "https://production.example.com?", "https://production.example.com#",
                   "https://production.example.com:444", "https://production.example.com:",
                   "https://Production.example.com", "https://production.example.com.", "https://bad_host.example.com",
                   "https://-bad.example.com", "https://production.example.com\n", " https://production.example.com",
                   "https://production.example.com\t", "https://production.example.com\x7f",
                   "https://production.example.com/%2F", "https://production.example.com\\evil",
                   "$(HGS_GATEWAY_URL)", "https://${GATEWAY_HOST}", "https://<gateway>", "https://placeholder",
                   "https://éxample.com", "https://[broken", "https://production.example.com:999999"]
        for field in ("HGS_PRODUCTION_GATEWAY_URL", "HGS_SANDBOX_GATEWAY_URL"):
            for value in invalid:
                with self.subTest(field=field, value=repr(value)), self.assertRaises(guards.ReleaseError):
                    config(**{field: value})
        self.assertEqual(self.fake.calls, [])

    def test_gateway_canonicalization_and_environment_separation(self):
        cfg = config(HGS_PRODUCTION_GATEWAY_URL=PRODUCTION + ":443/", HGS_SANDBOX_GATEWAY_URL=SANDBOX + "/")
        self.assertEqual((cfg.production_gateway, cfg.sandbox_gateway), (PRODUCTION, SANDBOX))
        for duplicate in (PRODUCTION, PRODUCTION + "/", PRODUCTION + ":443", PRODUCTION + ":443/"):
            with self.subTest(duplicate=duplicate), self.assertRaises(guards.ReleaseError):
                config(HGS_SANDBOX_GATEWAY_URL=duplicate)
        self.assertEqual(self.fake.calls, [])

    def test_missing_gateway_config_stops_main_before_runner(self):
        env = {"HGS_APP_ID": APP, "HGS_VERSION": "1.0.0"}
        for field in (None, "HGS_PRODUCTION_GATEWAY_URL", "HGS_SANDBOX_GATEWAY_URL"):
            candidate = dict(env)
            if field: candidate[field] = PRODUCTION
            with self.subTest(field=field), patch.dict(driver.os.environ, candidate, clear=True), \
                 patch.object(driver.sys, "argv", ["testflight.py", "ios", "upload-only"]), \
                 patch.object(driver, "Release") as release, patch("sys.stderr"):
                self.assertEqual(driver.main(), 1)
                release.assert_not_called()

    def test_gateway_config_rechecked_before_execute_side_effects(self):
        cfg = config()
        object.__setattr__(cfg, "sandbox_gateway", PRODUCTION)
        with self.assertRaises(guards.ReleaseError): self.release(cfg).execute()
        self.assertEqual(self.fake.calls, [])
        self.assertFalse((self.root / ".coordination").exists())

    def test_archive_gateway_mismatch_blocks_export_on_both_platforms(self):
        changes = [{"HGSProductionGatewayURL": None}, {"HGSSandboxGatewayURL": None},
                   {"HGSProductionGatewayURL": ""}, {"HGSSandboxGatewayURL": "$(HGS_SANDBOX_GATEWAY_URL)"},
                   {"HGSProductionGatewayURL": SANDBOX, "HGSSandboxGatewayURL": PRODUCTION},
                   {"HGSProductionGatewayURL": PRODUCTION + "/"}, {"HGSSandboxGatewayURL": "https://other.example.com"}]
        for platform in ("ios", "macos"):
            for change in changes:
                with self.subTest(platform=platform, change=change):
                    self.fake.calls.clear()
                    self.fake.archive_platform = "MacOSX" if platform == "macos" else "iPhoneOS"
                    self.fake.app_info_changes = change
                    with self.assertRaises(guards.ReleaseError): self.release(config(platform=platform)).execute()
                    self.no_upload()
                    self.assertFalse(any("-exportArchive" in c for c in self.fake.calls))

    def test_exact_gateway_settings_and_serial_swift_driver_in_archive_and_receipt(self):
        for platform in ("ios", "macos"):
            with self.subTest(platform=platform):
                self.fake.archive_platform = "MacOSX" if platform == "macos" else "iPhoneOS"
                self.fake.calls.clear()
                release = self.release(config("upload-only", platform=platform))
                release.execute()
                archive = next(c for c in self.fake.calls if c[0] == "xcodebuild" and "archive" in c)
                self.assertIn("HGS_PRODUCTION_GATEWAY_URL=" + PRODUCTION, archive)
                self.assertIn("HGS_SANDBOX_GATEWAY_URL=" + SANDBOX, archive)
                self.assertIn("OTHER_SWIFT_FLAGS=$(inherited) -driver-batch-count 1", archive)
                self.assertFalse(any("-j1" in a for a in archive))
                receipt = json.loads((release.directory / "release.json").read_text())
                self.assertEqual(receipt["gatewayOrigins"], {"production": PRODUCTION, "sandbox": SANDBOX})

    def test_runner_disables_diskcleaner_tui_only_in_child_environment(self):
        result = subprocess.CompletedProcess([], 0, stdout=b"", stderr=b"")
        with patch.dict(os.environ, {"DISKCLEANER_TUI": "1", "HGS_SYNTHETIC_PARENT": "preserved"}), \
             patch.object(driver.subprocess, "run", return_value=result) as run:
            driver.Runner().run(["fake"], self.root)
            child = run.call_args.kwargs["env"]
            self.assertEqual(child["DISKCLEANER_TUI"], "0")
            self.assertEqual(child["HGS_SYNTHETIC_PARENT"], "preserved")
            self.assertEqual(os.environ["DISKCLEANER_TUI"], "1")

    def test_dirty_source_rejected_before_remote_or_build(self):
        self.fake.dirty = True
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.assertEqual(len(self.fake.calls), 1)

    def test_wrong_app_external_group_missing_and_inactive_testers_prevent_build(self):
        cases = [(("apps", "view"), lambda r: r["data"]["attributes"].update(bundleId="wrong")),
                 (("testflight", "groups", "view"), lambda r: r["data"]["attributes"].update(isInternalGroup=False)),
                 (("testflight", "groups", "app", "view"), lambda r: r["data"].update(id="999")),
                 (("testflight", "groups", "testers", "list"), lambda r: r.update(data=[])),
                 (("testflight", "groups", "testers", "list"), lambda r: r["data"][0]["attributes"].update(state="INVITED"))]
        for prefix, change in cases:
            with self.subTest(prefix=prefix):
                self.fake.calls.clear()
                def mutate(args, response):
                    if args[1:1+len(prefix)] == prefix: change(response)
                    return response
                self.fake.mutate = mutate
                with self.assertRaises(guards.ReleaseError): self.release().execute()
                self.no_build()

    def test_invalid_and_old_build_number_prevents_build(self):
        with self.assertRaises(guards.ReleaseError): self.release(config(HGS_BUILD_NUMBER="6")).execute()
        self.no_build()
        self.fake.number = "unknown"
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.no_build()

    def test_full_verification_failure_blocks_archive_and_upload(self):
        self.fake.fail = lambda args: args[0] == "bash"
        release = self.release()
        with self.assertRaises(guards.ReleaseError): release.execute()
        self.no_upload()
        self.assertFalse(any(c[0] == "xcodebuild" for c in self.fake.calls))
        self.assertTrue((release.directory / "release.json").is_file())

    def test_archive_identity_and_ambiguous_exports_block_upload(self):
        for change in ({"Team": "wrong"}, {"CFBundleVersion": "8"}, {"CFBundleIdentifier": "other"}):
            self.fake.archive_changes = change
            with self.assertRaises(guards.ReleaseError): self.release().execute()
            self.no_upload()
        self.fake.archive_changes = {}
        self.fake.artifact_count = 2
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.no_upload()

    def test_wrong_archive_platform_blocks_upload(self):
        self.fake.archive_platform = "AppleTVOS"
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.no_upload()

    def test_internal_success_records_exact_identity_and_readiness_without_secrets(self):
        release = self.release()
        result = release.execute()
        evidence = json.loads((release.directory / "release.json").read_text())
        self.assertEqual(evidence["phase"], "internal_available")
        self.assertEqual(evidence["sourceCommit"], COMMIT)
        self.assertEqual(evidence["buildId"], BUILD)
        self.assertEqual(evidence["installedOnDevice"], "not_verified")
        self.assertEqual(len(evidence["artifactSHA256"]), 64)
        self.assertIn("installation is not verified", result)
        self.assertIn(("asc", "builds", "add-groups", "--build-id", BUILD, "--group", GROUP, "--output", "json"), self.fake.calls)
        all_receipts = "".join(p.read_text() for p in release.directory.glob("*.json"))
        self.assertNotIn("presignedURL", all_receipts)
        self.assertNotIn("capability", all_receipts)
        verify = next(c for c in self.fake.calls if c[0] == "bash")
        self.assertEqual(verify[-1], "full")
        self.assertTrue((release.directory / "HomeGardenStudio.xcarchive").is_dir())

    def test_upload_only_never_assigns_groups_or_claims_tester_availability(self):
        result = self.release(config("upload-only")).execute()
        self.assertIn("no tester availability claimed", result)
        self.assertFalse(any("add-groups" in c or "testflight" in c for c in self.fake.calls))

    def test_missing_receipt_and_mismatched_processed_builds_fail_before_assignment(self):
        mutations = [lambda r: r.pop("buildId", None),
                     lambda r: r["data"]["attributes"].update(processingState="PROCESSING"),
                     lambda r: r["data"]["attributes"].update(expired=True),
                     lambda r: r["data"].update(id=GROUP),
                     lambda r: r["data"]["attributes"].update(version="99"),
                     lambda r: r["included"][0]["attributes"].update(platform="MAC_OS"),
                     lambda r: r["included"][0]["attributes"].update(version="2.0.0"),
                     lambda r: r["data"]["relationships"]["app"]["data"].update(id="999")]
        for index, change in enumerate(mutations):
            with self.subTest(index=index):
                case_root = self.root / str(index)
                case_root.mkdir()
                self.fake = FakeRunner(case_root)
                def mutate(args, response):
                    target = "upload" if index == 0 else "info"
                    if args[1:3] == ("builds", target): change(response)
                    return response
                self.fake.mutate = mutate
                with self.assertRaises(guards.ReleaseError): driver.Release(case_root, config(), self.fake).execute()
                self.assertTrue(any(c[:3] == ("asc", "builds", "upload") for c in self.fake.calls))
                self.assertFalse(self.fake.assigned)

    def test_postassignment_membership_and_readiness_are_separate_gates(self):
        for failure in ("membership", "tester", "readiness", "relationship"):
            self.fake.assigned = False
            def mutate(args, response):
                if self.fake.assigned:
                    if failure == "membership" and args[1:5] == ("testflight", "groups", "builds", "list"): response["data"] = []
                    if failure == "tester" and args[1:5] == ("testflight", "groups", "testers", "list"): response["data"] = []
                    if args[1:3] == ("builds", "info"):
                        if failure == "readiness": response["included"][1]["attributes"]["internalBuildState"] = "READY_FOR_BETA_TESTING"
                        if failure == "relationship": response["data"]["relationships"]["betaGroups"]["data"] = []
                return response
            self.fake.mutate = mutate
            release = self.release()
            with self.subTest(failure=failure), self.assertRaises(guards.ReleaseError): release.execute()
            self.assertFalse((release.directory / "availability.json").exists())

    def test_retry_preserves_prior_archive_and_receipts(self):
        first = self.release(); first.execute()
        before = (first.directory / "release.json").read_bytes()
        self.fake.fail = lambda args: args[:3] == ("asc", "builds", "upload")
        second = self.release()
        with self.assertRaises(guards.ReleaseError): second.execute()
        self.assertNotEqual(first.directory, second.directory)
        self.assertEqual((first.directory / "release.json").read_bytes(), before)
        self.assertTrue((first.directory / "HomeGardenStudio.xcarchive/Info.plist").exists())

    def test_unknown_and_unpaginated_asc_schema_fails_closed(self):
        for response in ([], {"data": {}}, {"data": [], "links": {"next": "another page"}}):
            with self.assertRaises(guards.ReleaseError): guards.listed(response, "betaTesters")
        self.fake.mutate = lambda args, response: {} if args[1:3] == ("builds", "info") else response
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.assertFalse(self.fake.assigned)

    def test_source_and_number_races_block_upload(self):
        self.fake.fail = None
        original = self.fake.run
        def dirty_after_verify(args, cwd):
            result = original(args, cwd)
            if str(args[0]) == "bash": self.fake.dirty = True
            return result
        self.fake.run = dirty_after_verify
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.no_upload()
        self.fake.run = original
        self.fake.dirty = False
        seen = 0
        def increase_next(args, response):
            nonlocal seen
            if args[1:3] == ("builds", "next-build-number"):
                seen += 1
                if seen == 2: response["nextBuildNumber"] = "8"
            return response
        self.fake.mutate = increase_next
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.no_upload()

    def test_audience_change_after_processing_blocks_assignment(self):
        uploaded = False
        def mutate(args, response):
            nonlocal uploaded
            if args[1:3] == ("builds", "upload"): uploaded = True
            if uploaded and args[1:4] == ("testflight", "groups", "view"):
                response["data"]["attributes"]["isInternalGroup"] = False
            return response
        self.fake.mutate = mutate
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.assertFalse(self.fake.assigned)

    def test_invalid_upload_identity_cannot_leak_in_receipt(self):
        synthetic = "private" + "-capability-fixture"
        self.fake.mutate = lambda args, response: {"buildId": synthetic} if args[1:3] == ("builds", "upload") else response
        release = self.release()
        with self.assertRaises(guards.ReleaseError): release.execute()
        receipt = (release.directory / "upload-receipt.json").read_text()
        self.assertNotIn(synthetic, receipt)
        self.assertIsNone(json.loads(receipt)["buildId"])

    def test_subprocess_errors_do_not_echo_output(self):
        synthetic = "synthetic" + "-secret-output"
        result = subprocess.CompletedProcess([], 1, stdout=synthetic.encode(), stderr=synthetic.encode())
        with patch.object(driver.subprocess, "run", return_value=result):
            with self.assertRaises(guards.ReleaseError) as raised:
                driver.Runner().run(["fake"], self.root)
        self.assertNotIn(synthetic, str(raised.exception))

    def test_unconfirmed_upload_requires_reconciliation_before_retry(self):
        self.fake.fail = lambda args: args[:3] == ("asc", "builds", "upload")
        first = self.release()
        with self.assertRaises(guards.ReleaseError): first.execute()
        self.fake.calls.clear()
        with self.assertRaises(guards.ReleaseError): self.release().execute()
        self.assertEqual(self.fake.calls, [])
        self.assertTrue((first.directory / "HomeGardenStudio.xcarchive/Info.plist").exists())

    def test_shell_and_export_plists_parse(self):
        subprocess.run(["bash", "-n", str(RELEASE / "testflight.sh")], check=True, capture_output=True)
        for name in ("ios", "macos"):
            with (RELEASE / ("exportOptions-" + name + ".plist")).open("rb") as handle:
                self.assertEqual(plistlib.load(handle)["teamID"], guards.TEAM)
