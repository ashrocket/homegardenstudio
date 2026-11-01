#!/usr/bin/env python3
"""Archive and upload only after explicit configuration and verified source gates."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid
from guards import (BUNDLE, TEAM, Config, ReleaseError, require, identifier,
                    resource, listed, check_app, check_group, check_tester,
                    select_number, check_build)


class Runner:
    def run(self, args, cwd, timeout=3600):
        try:
            result = subprocess.run([str(a) for a in args], cwd=cwd, capture_output=True,
                                    timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReleaseError("Release command failed or timed out; retained evidence requires review before retry") from error
        require(result.returncode == 0, "Release command failed; raw command output was withheld")
        require(len(result.stdout) <= 16 * 1024 * 1024, "Command response exceeds release receipt limit")
        return result.stdout


class Release:
    def __init__(self, root, cfg, runner=None):
        self.root, self.cfg, self.runner = root, cfg, runner or Runner()
        self.directory = None
        self.evidence = {}

    def run(self, *args, cwd=None):
        return self.runner.run(args, cwd or self.root)

    def asc(self, *args):
        raw = self.run("asc", *args, "--output", "json")
        try:
            response = json.loads(raw)
        except (ValueError, UnicodeError) as error:
            raise ReleaseError("ASC did not return valid JSON") from error
        require(isinstance(response, dict), "Unknown ASC top-level response schema")
        return response

    def clean_source(self):
        require(not self.run("git", "status", "--porcelain=v1", "-z", "--untracked-files=all"),
                "Release requires a clean tracked, staged and untracked source tree")
        commit = self.run("git", "rev-parse", "HEAD").decode("ascii").strip()
        require(len(commit) == 40 and all(c in "0123456789abcdef" for c in commit), "Unknown Git source identity")
        return commit

    def write(self, name, value):
        path = self.directory / name
        temporary = path.with_suffix(".pending")
        temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        temporary.replace(path)

    def phase(self, phase, **values):
        self.evidence.update(phase=phase, **values)
        self.write("release.json", self.evidence)

    def audience(self):
        cfg = self.cfg
        check_group(self.asc("testflight", "groups", "view", "--id", cfg.group), cfg)
        resource(self.asc("testflight", "groups", "app", "view", "--group-id", cfg.group), "apps", cfg.app)
        return check_tester(self.asc("testflight", "groups", "testers", "list", "--group-id", cfg.group, "--paginate"), cfg)

    def build_info(self, number, build_id, available=False):
        response = self.asc("builds", "info", "--build-id", build_id,
                            "--include", "preReleaseVersion,app,buildBetaDetail,betaGroups")
        return check_build(response, self.cfg, number, build_id, available)

    def reject_unresolved_uploads(self):
        previous = self.root / ".coordination" / "releases"
        if not previous.exists():
            return
        for path in previous.glob("*/*/*/*/release.json"):
            try:
                require(path.stat().st_size <= 1024 * 1024, "Prior release evidence exceeds its size limit")
                record = json.loads(path.read_text())
            except (OSError, ValueError) as error:
                raise ReleaseError("Cannot inspect prior release evidence; reconcile it before retry") from error
            require(isinstance(record, dict) and record.get("schema") == 1, "Unknown prior release evidence schema")
            if record.get("appId") == self.cfg.app and record.get("platform") == self.cfg.asc_platform:
                require(record.get("phase") != "upload_started", "A prior upload has no confirmed response; reconcile its ASC outcome before another upload")

    def execute(self):
        cfg = self.cfg
        self.reject_unresolved_uploads()
        commit = self.clean_source()
        # All remote calls before full verification are read-only identity/configuration gates.
        check_app(self.asc("apps", "view", "--id", cfg.app), cfg)
        if cfg.mode == "internal":
            self.audience()
        next_args = ("builds", "next-build-number", "--app", cfg.app, "--platform", cfg.asc_platform)
        # Deliberately include all marketing versions and expired/in-flight builds.
        number = select_number(self.asc(*next_args), cfg)
        self.directory = self.root / ".coordination" / "releases" / cfg.platform / cfg.version / number / uuid.uuid4().hex
        self.directory.mkdir(parents=True, mode=0o700, exist_ok=False)
        self.evidence = {"schema": 1, "sourceCommit": commit, "appId": cfg.app, "bundleId": BUNDLE,
                         "teamId": TEAM, "platform": cfg.asc_platform, "version": cfg.version,
                         "buildNumber": number, "mode": cfg.mode, "groupId": cfg.group,
                         "testerId": cfg.tester, "installedOnDevice": "not_verified"}
        self.phase("preflight_passed")
        self.run(Path.home() / "ashcode/diskcleaner/bin/diskcleaner", "check")
        self.phase("full_verification_started")
        self.run("bash", self.root / "scripts/verify.sh", "full")
        require(self.clean_source() == commit, "Source changed during full verification")
        self.phase("full_verification_passed")
        apple = self.root / "apple"
        self.run("xcodegen", "generate", cwd=apple)
        archive = self.directory / "HomeGardenStudio.xcarchive"
        destination = "generic/platform=iOS" if cfg.platform == "ios" else "generic/platform=macOS"
        profile = "HomeGardenStudio iOS App Store" if cfg.platform == "ios" else "HomeGardenStudio Mac App Store"
        self.phase("archive_started")
        self.run("xcodebuild", "-project", "HomeGardenStudio.xcodeproj", "-scheme", "HomeGardenStudio",
                 "-configuration", "Release", "-jobs", "1", "-destination", destination, "-archivePath", archive,
                 "-derivedDataPath", self.directory / "derived", "CODE_SIGN_STYLE=Manual",
                 "OTHER_SWIFT_FLAGS=$(inherited) -j1",
                 "CODE_SIGN_IDENTITY=Apple Distribution", "DEVELOPMENT_TEAM=" + TEAM,
                 "PROVISIONING_PROFILE_SPECIFIER=" + profile, "CURRENT_PROJECT_VERSION=" + number,
                 "MARKETING_VERSION=" + cfg.version, "archive", cwd=apple)
        try:
            with (archive / "Info.plist").open("rb") as handle:
                properties = plistlib.load(handle)["ApplicationProperties"]
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise ReleaseError("Cannot validate archived application identity") from error
        require(isinstance(properties, dict) and all(properties.get(k) == v for k, v in {
            "CFBundleIdentifier": BUNDLE, "CFBundleVersion": number,
            "CFBundleShortVersionString": cfg.version, "Team": TEAM}.items()),
            "Archived bundle, team, version or build number does not match the release")
        app_path = properties.get("ApplicationPath")
        require(isinstance(app_path, str), "Archive is missing its application path")
        relative_app = Path(app_path)
        require(not relative_app.is_absolute() and ".." not in relative_app.parts and relative_app.suffix == ".app",
                "Archive application path is not a contained app bundle")
        application = archive / "Products" / relative_app
        require(application.resolve().is_relative_to(archive.resolve()), "Archive application escapes the archive")
        app_info = application / ("Info.plist" if cfg.platform == "ios" else "Contents/Info.plist")
        try:
            with app_info.open("rb") as handle:
                app_properties = plistlib.load(handle)
        except (OSError, ValueError) as error:
            raise ReleaseError("Cannot read archived application platform") from error
        supported = "iPhoneOS" if cfg.platform == "ios" else "MacOSX"
        require(isinstance(app_properties, dict) and app_properties.get("CFBundleSupportedPlatforms") == [supported],
                "Archived application platform does not match release platform")
        self.phase("archived", archive=str(archive.relative_to(self.root)))
        export = self.directory / "export"
        self.phase("export_started")
        self.run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", export,
                 "-exportOptionsPlist", self.root / "scripts/release" / ("exportOptions-" + cfg.platform + ".plist"))
        artifacts = list(export.glob("*." + cfg.extension))
        require(len(artifacts) == 1 and artifacts[0].is_file() and not artifacts[0].is_symlink(),
                "Export must contain exactly one regular upload artifact")
        artifact = artifacts[0]
        with artifact.open("rb") as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
            checksum = digest.hexdigest()
        self.phase("exported", artifact=str(artifact.relative_to(self.root)), artifactSHA256=checksum)
        require(self.clean_source() == commit, "Source changed before upload")
        # Recheck uniqueness and audience immediately before the irreversible upload.
        require(select_number(self.asc(*next_args), cfg) == number, "Build-number availability changed; archive retained")
        if cfg.mode == "internal":
            self.audience()
        self.phase("upload_started")
        receipt = self.asc("builds", "upload", "--app", cfg.app, "--" + cfg.extension, artifact,
                           "--wait", "--checksum", "--version", cfg.version, "--build-number", number)
        # Retain only an allowlisted projection: even unexpected CLI fields cannot leak credentials.
        build_id = receipt.get("buildId")
        try:
            identifier(build_id)
            safe_build_id = build_id
        except ReleaseError:
            safe_build_id = None
        self.write("upload-receipt.json", {"schema": 1, "redactedProjection": True,
                   "buildId": safe_build_id,
                   "responseSHA256": hashlib.sha256(json.dumps(receipt, sort_keys=True).encode()).hexdigest()})
        identifier(build_id)
        self.phase("upload_returned", buildId=build_id)
        verified = self.build_info(number, build_id)
        self.write("processed-build.json", verified)
        self.phase("processed_valid")
        if cfg.mode == "upload-only":
            return "Upload and VALID processing verified; no tester availability claimed."
        # Audience may have changed during processing. Recheck before assignment.
        self.audience()
        self.asc("builds", "add-groups", "--build-id", build_id, "--group", cfg.group)
        self.phase("group_assignment_returned")
        group_builds = listed(self.asc("testflight", "groups", "builds", "list", "--group-id", cfg.group, "--paginate"), "builds")
        require(any(b["id"] == build_id for b in group_builds), "Exact build is absent from group readback")
        tester_state = self.audience()
        verified = self.build_info(number, build_id, available=True)
        self.write("availability.json", {**verified, "groupId": cfg.group, "testerId": cfg.tester,
                                         "testerState": tester_state, "installedOnDevice": "not_verified"})
        self.phase("internal_available")
        return "Exact build is available to the verified internal group and intended tester; installation is not verified."


def main():
    release = None
    try:
        cfg = Config.parse(sys.argv[1:], os.environ)
        release = Release(Path(__file__).resolve().parents[2], cfg)
        print(release.execute())
        return 0
    except (ReleaseError, OSError, UnicodeError, ValueError, TypeError, RecursionError) as error:
        if release and release.directory:
            # Preserve the last phase: an upload_started failure may have uploaded remotely.
            release.evidence["requiresReviewBeforeRetry"] = True
            try:
                release.write("release.json", release.evidence)
            except OSError:
                pass
        print("Release stopped: " + (str(error) if isinstance(error, ReleaseError) else "Local evidence or filesystem operation failed"), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
