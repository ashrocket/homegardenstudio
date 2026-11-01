#!/usr/bin/env python3
"""Check actual Apple-only compiler inputs and built bundles, without launching an app."""
import argparse
import json
from pathlib import Path
import plistlib
import sys

ALLOWED = {
    "HomeGardenStudioApp.swift",
    "AI/LocalAssistant.swift", "AI/LocalEvidenceAnalysis.swift", "AI/AppleConceptImage.swift",
    "Document/PlanStore.swift", "Document/PlanDocument.swift",
    "Engine/HgsEngine.swift", "Engine/EngineModels.swift",
    "Import/DropImport.swift", "Import/ImportService.swift",
    "Views/AppleConceptSheet.swift", "Views/AssistantSheet.swift", "Views/InspectorPanel.swift",
    "Views/LayoutImageExport.swift", "Views/LibraryPanel.swift", "Views/PlanCanvasView.swift",
    "Views/PreviewViews.swift", "Views/RenderImagePreview.swift", "Views/SavedConceptsSheet.swift",
    "Views/SourcesPanel.swift", "Views/StudioServices.swift", "Views/WorkspaceView.swift",
}
FORBIDDEN_INFO = {"HGSProductionGatewayURL", "HGSSandboxGatewayURL", "HGSKeychainAccessGroup"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inspect(derived):
    result = []
    for configuration, contents in (("Debug", "Contents"), ("Debug-iphonesimulator", "")):
        app = derived / "Build/Products" / configuration / "HomeGardenStudioApple.app"
        root = app / contents
        with (root / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        require(info.get("CFBundleIdentifier") == "com.ashleyraiteri.homegardenstudio.appleonly", "Wrong Apple-only bundle identifier")
        require(info.get("HGSAppleOnly") is True, "Missing Apple-only build marker")
        require(not FORBIDDEN_INFO.intersection(info), "Cloud or keychain configuration leaked into Apple-only bundle")
        require(not info.get("NSAppTransportSecurity", {}).get("NSAllowsLocalNetworking"), "Loopback networking exemption leaked into Apple-only bundle")
        privacy_path = root / ("Resources" if contents else "") / "PrivacyInfo.xcprivacy"
        with privacy_path.open("rb") as stream:
            privacy = plistlib.load(stream)
        require(privacy.get("NSPrivacyTracking") is False, "Apple-only build must not track")
        require(privacy.get("NSPrivacyCollectedDataTypes") == [], "Cloud collection declarations leaked into Apple-only bundle")
        require(privacy.get("NSPrivacyTrackingDomains") == [], "Apple-only build has tracking domains")
        intermediate = derived / "Build/Intermediates.noindex/HomeGardenStudio.build" / configuration / "HomeGardenStudioApple.build"
        lists = sorted(intermediate.glob("Objects-normal/*/HomeGardenStudioApple.SwiftFileList"))
        require(bool(lists), "Missing actual Apple-only compiler file list")
        for file_list in lists:
            source_files = set()
            for raw in file_list.read_text().splitlines():
                path = Path(raw.strip().strip('"'))
                if path.name == "GeneratedAssetSymbols.swift" and "DerivedSources" in path.parts:
                    continue
                parts = path.parts
                require("HomeGardenStudio" in parts, "Unexpected compiler input: " + path.name)
                relative = "/".join(parts[parts.index("HomeGardenStudio") + 1:])
                require(relative in ALLOWED, "Unapproved Apple-only compiler input: " + relative)
                source_files.add(relative)
            require(source_files == ALLOWED, "Apple-only build is missing required editor or Apple AI source files")
        result.append({"configuration": configuration, "bundle": str(app), "compiler_inputs": len(ALLOWED), "checks": "passed"})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps({"apple_only_builds": inspect(args.derived_data.resolve())}, indent=2))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print("Apple-only build check failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
