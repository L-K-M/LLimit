#!/usr/bin/env python3
"""Keep llimit --version aligned with project.yml or a release tag.

Usage: python3 scripts/stamp-llimit-version.py [VERSION] [--check]
"""
import argparse
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "Packages/LLimitd/Sources/LLimitdCore/Version.swift"
DECLARATION = re.compile(r'(public static let version = ")[^"]+("\s*)')


def stamped(source, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z.]+)?", version):
        raise ValueError("invalid release version")
    updated, count = DECLARATION.subn(lambda match: match[1] + version + match[2], source)
    if count != 1:
        raise ValueError("expected one LLimitdInfo.version declaration")
    return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    version = args.version
    if version is None:
        match = re.search(r"^\s*MARKETING_VERSION:\s*[\"']?([0-9][0-9A-Za-z.-]*)", (ROOT / "project.yml").read_text(), re.MULTILINE)
        if match is None:
            parser.error("project.yml has no release version")
        version = match[1]
    try:
        source = VERSION_FILE.read_text()
        updated = stamped(source, version)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    if args.check:
        if source != updated:
            parser.error(f"llimit version does not match {version}")
        return
    if source != updated:
        VERSION_FILE.write_text(updated)


if __name__ == "__main__":
    main()
