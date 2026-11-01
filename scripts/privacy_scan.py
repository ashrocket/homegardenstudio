#!/usr/bin/env python3
"""Scan index and working source; report identifiers, never matched secrets.

This aids source publication. Photos and compressed documents still require
deliberate review; a clean scan cannot establish that arbitrary assets are safe.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

MAX_FILE_BYTES = 16 * 1024 * 1024
RULES = (
    ("anthropic-key", r"sk-ant-[A-Za-z0-9_-]{20,}"),
    ("openai-key", r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}"),
    ("account-secret", r"hgs_[A-Za-z0-9_-]{40,}"),
    ("private-key", r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    ("signing-key-file", r"AuthKey_[A-Z0-9]{10}\.p8"),
    ("private-storage", r"r2\.cloudflarestorage\.com"),
    ("github-token", r"gho_[A-Za-z0-9]{20,}"),
    ("slack-token", r"xox[bap]-[A-Za-z0-9-]{10,}"),
    ("precise-coordinates", r"-?[0-9]{2}\.[0-9]{5,}, ?-?[0-9]{2,3}\.[0-9]{5,}"),
)


class ScanError(Exception):
    pass


def git(root, *args):
    try:
        proc = subprocess.run(["git", "-C", str(root), *args],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ScanError("Git command could not complete") from error
    if proc.returncode:
        raise ScanError("Git could not read the selected source")
    return proc.stdout


def load_rules(root):
    rules = [(name, re.compile(pattern)) for name, pattern in RULES]
    private = root / ".coordination/private-patterns.txt"
    if private.exists():
        try:
            if private.stat().st_size > 256 * 1024:
                raise ScanError("Private pattern file exceeds its size limit")
            for index, line in enumerate(private.read_text(encoding="utf-8").splitlines(), 1):
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                try:
                    rules.append(("private-rule-" + str(index), re.compile(line, re.IGNORECASE)))
                except re.error as error:
                    raise ScanError("Invalid private rule at line " + str(index)) from error
        except (OSError, UnicodeError) as error:
            raise ScanError("Cannot read the private pattern file") from error
    return rules


def safe_path(name, rules):
    # Evaluate every rule against the original name. Redacting one match must
    # not remove context needed by a later private rule and expose that match.
    if any(pattern.search(name) for _, pattern in rules):
        digest = hashlib.sha256(os.fsencode(name)).hexdigest()[:12]
        return json.dumps("[redacted]-" + digest)
    return json.dumps(name, ensure_ascii=True)


def text_candidates(data):
    yield data.decode("utf-8", errors="replace")
    if b"\0" in data or data.startswith((b"\xff\xfe", b"\xfe\xff")):
        # UTF-16/32 source and metadata can contain ordinary ASCII credentials.
        # Consider both byte orders without requiring a BOM. Zero stripping also
        # detects ASCII secrets inside unaligned, zero-padded binary metadata.
        for encoding in ("utf-16-le", "utf-16-be", "utf-32-le", "utf-32-be"):
            yield data.decode(encoding, errors="replace")
        yield data.replace(b"\0", b"").decode("utf-8", errors="replace")


def inspect_bytes(data, name, source, rules):
    found = set()
    for text in text_candidates(data):
        for rule, pattern in rules:
            match = pattern.search(text) if rule not in found else None
            if match:
                line = text.count("\n", 0, match.start()) + 1
                print("privacy-scan: match source={} file={} line={} rule={}".format(
                    source, safe_path(name, rules), line, rule))
                found.add(rule)
    return bool(found)


def scan(root):
    rules = load_rules(root)
    matched = False
    count = 0
    # Immutable object IDs prevent working edits from concealing staged secrets.
    for entry in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        try:
            metadata, raw_path = entry.split(b"\t", 1)
            mode, oid, stage = metadata.split()
            name = os.fsdecode(raw_path)
            if stage != b"0":
                raise ScanError("Resolve unmerged index entries before publication")
            if mode == b"160000":
                raise ScanError("Submodule content requires a separate publication scan")
            size = int(git(root, "cat-file", "-s", oid.decode("ascii")))
        except (ValueError, UnicodeError) as error:
            raise ScanError("Invalid Git index metadata") from error
        if size > MAX_FILE_BYTES:
            raise ScanError("Indexed file exceeds scan limit: " + safe_path(name, rules))
        matched |= inspect_bytes(git(root, "cat-file", "blob", oid.decode("ascii")), name, "index", rules)
        matched |= inspect_bytes(raw_path, name, "filename", rules)
        count += 1
    names = set(git(root, "ls-files", "-c", "-o", "--exclude-standard", "-z").split(b"\0"))
    for raw_path in sorted(names):
        if not raw_path:
            continue
        name = os.fsdecode(raw_path)
        path = root / name
        try:
            if path.is_symlink():
                data = os.fsencode(os.readlink(path))
            elif not path.exists():
                continue  # A deleted tracked file was scanned from its index blob.
            elif not path.is_file():
                raise ScanError("Non-file source requires review: " + safe_path(name, rules))
            else:
                with path.open("rb") as handle:
                    data = handle.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise ScanError("Working file exceeds scan limit: " + safe_path(name, rules))
        except OSError as error:
            raise ScanError("Cannot read source: " + safe_path(name, rules)) from error
        matched |= inspect_bytes(data, name, "working", rules)
        matched |= inspect_bytes(raw_path, name, "filename", rules)
        count += 1
    if not matched:
        print("privacy-scan: clean ({} index/working entries checked)".format(count))
    return 1 if matched else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        return scan(args.root.resolve())
    except ScanError as error:
        print("privacy-scan: error: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
