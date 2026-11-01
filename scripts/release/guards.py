"""Strict release configuration and ASC response checks; no side effects."""
from __future__ import annotations
from dataclasses import dataclass
import re

BUNDLE = "com.ashleyraiteri.homegardenstudio"
TEAM = "6P24N3R4TP"


class ReleaseError(Exception):
    """Messages are fixed operational descriptions, never subprocess output."""


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value),
            "Expected one UUID resource ID; names, lists and whitespace are not accepted")
    return value


def build_number(value):
    require(type(value) in (int, str), "Unknown build-number response schema")
    text = str(value)
    require(re.fullmatch(r"[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}", text),
            "Build number must have a positive 1-4 digit first component and up to two 1-2 digit components")
    return text


def number_tuple(value):
    parts = tuple(int(v) for v in value.split('.'))
    return parts + (0,) * (3-len(parts))


@dataclass(frozen=True)
class Config:
    platform: str
    mode: str
    app: str
    version: str
    group: str | None
    tester: str | None
    override: str | None

    @property
    def asc_platform(self):
        return {"ios": "IOS", "macos": "MAC_OS"}[self.platform]

    @property
    def extension(self):
        return "ipa" if self.platform == "ios" else "pkg"

    @classmethod
    def parse(cls, argv, env):
        require(len(argv) == 2 and argv[0] in ("ios", "macos") and argv[1] in ("upload-only", "internal"),
                "Usage: testflight.sh ios|macos upload-only|internal")
        app = env.get("HGS_APP_ID", "")
        require(re.fullmatch(r"[1-9][0-9]{0,19}", app), "HGS_APP_ID must be the numeric ASC app ID")
        version = env.get("HGS_VERSION", "")
        require(re.fullmatch(r"[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}", version),
                "Set HGS_VERSION to the explicit three-component marketing version")
        group, tester = env.get("HGS_GROUP"), env.get("HGS_TESTER_ID")
        if argv[1] == "internal":
            require(group and tester, "Internal mode requires HGS_GROUP and HGS_TESTER_ID")
            identifier(group)
            identifier(tester)
        else:
            require(not group and not tester, "Upload-only mode must not specify a group or tester")
        override = env.get("HGS_BUILD_NUMBER")
        if override is not None:
            override = build_number(override)
        return cls(argv[0], argv[1], app, version, group, tester, override)


def resource(response, kind, expected_id=None):
    require(isinstance(response, dict), "Unknown ASC response schema")
    item = response.get("data")
    require(isinstance(item, dict) and item.get("type") == kind, "Unknown ASC resource schema")
    if kind == "apps":
        require(isinstance(item.get("id"), str) and re.fullmatch(r"[1-9][0-9]{0,19}", item["id"]), "Unknown app identity schema")
    else:
        identifier(item.get("id"))
    if expected_id is not None:
        require(item["id"] == expected_id, "ASC resource identity mismatch")
    return item


def attributes(item):
    result = item.get("attributes")
    require(isinstance(result, dict), "Missing ASC resource attributes")
    return result


def listed(response, kind):
    require(isinstance(response, dict) and isinstance(response.get("data"), list), "Unknown ASC list schema")
    links = response.get("links", {})
    require(isinstance(links, dict) and not links.get("next"), "ASC pagination is incomplete")
    for item in response["data"]:
        require(isinstance(item, dict) and item.get("type") == kind, "Unexpected resource in ASC list")
        identifier(item.get("id"))
    return response["data"]


def check_app(response, cfg):
    app = resource(response, "apps", cfg.app)
    require(attributes(app).get("bundleId") == BUNDLE, "ASC app bundle identifier does not match HomeGardenStudio")


def check_group(response, cfg):
    group = resource(response, "betaGroups", cfg.group)
    require(attributes(group).get("isInternalGroup") is True, "Selected group is not a verified internal group")


def check_tester(response, cfg):
    matches = [t for t in listed(response, "betaTesters") if t["id"] == cfg.tester]
    require(len(matches) == 1, "Intended existing tester is not uniquely present in the group")
    state = attributes(matches[0]).get("state")
    require(state in ("ACCEPTED", "INSTALLED"), "Intended tester has not accepted access or has unknown readiness")
    return state


def select_number(response, cfg):
    require(isinstance(response, dict) and "nextBuildNumber" in response, "Missing nextBuildNumber")
    suggested = build_number(response["nextBuildNumber"])
    chosen = cfg.override or suggested
    require(number_tuple(chosen) >= number_tuple(suggested), "Build-number override is older than the next unused number")
    return chosen


def related(item, name, kind):
    relationships = item.get("relationships")
    require(isinstance(relationships, dict), "Missing build relationships")
    relation = relationships.get(name)
    require(isinstance(relation, dict), "Missing build relationship")
    result = relation.get("data")
    require(isinstance(result, dict) and result.get("type") == kind, "Unknown build relationship schema")
    if kind == "apps":
        require(isinstance(result.get("id"), str) and re.fullmatch(r"[1-9][0-9]{0,19}", result["id"]), "Unknown app relationship schema")
    else:
        identifier(result.get("id"))
    return result["id"]


def included(response, kind, resource_id):
    items = response.get("included")
    require(isinstance(items, list), "Missing included build resources")
    matches = [item for item in items if isinstance(item, dict) and item.get("type") == kind and item.get("id") == resource_id]
    require(len(matches) == 1, "Missing or ambiguous included build resource")
    return matches[0]


def check_build(response, cfg, number, build_id, available=False):
    build = resource(response, "builds", build_id)
    attrs = attributes(build)
    require(attrs.get("processingState") == "VALID" and attrs.get("expired") is False,
            "Build is not VALID and explicitly unexpired")
    require(attrs.get("version") == number, "Processed build number mismatch")
    require(related(build, "app", "apps") == cfg.app, "Processed build belongs to another app")
    version_id = related(build, "preReleaseVersion", "preReleaseVersions")
    version = attributes(included(response, "preReleaseVersions", version_id))
    require(version.get("version") == cfg.version and version.get("platform") == cfg.asc_platform,
            "Processed build marketing version or platform mismatch")
    if available:
        detail_id = related(build, "buildBetaDetail", "buildBetaDetails")
        detail = attributes(included(response, "buildBetaDetails", detail_id))
        require(detail.get("internalBuildState") == "IN_BETA_TESTING", "Build is not available for internal testing")
        groups = build["relationships"].get("betaGroups")
        require(isinstance(groups, dict), "Missing build group relationship")
        require(any(g["id"] == cfg.group for g in listed(groups, "betaGroups")), "Exact build is not related to the intended group")
    return {"buildId": build_id, "processingState": "VALID", "expired": False,
            "appId": cfg.app, "platform": cfg.asc_platform, "version": cfg.version,
            "buildNumber": number, "internalAvailable": available}
