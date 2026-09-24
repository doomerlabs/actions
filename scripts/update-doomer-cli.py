#!/usr/bin/env python3
"""Select a published Doomer release and update action defaults and docs."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAG = re.compile(r"^(20\d{2})\.(\d{1,2})\.(\d{1,2})(?:-beta\.(\d+))?$")


def version_key(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError(f"invalid Doomer release tag: {tag}")
    year, month, day, beta = match.groups()
    return (int(year), int(month), int(day), beta is None, int(beta or 0))


def latest_release(path):
    releases = json.loads(Path(path).read_text())
    candidates = [release["tag_name"] for release in releases
                  if not release["draft"] and release["published_at"]
                  and TAG.fullmatch(release["tag_name"])]
    if not candidates:
        raise ValueError("no published CalVer Doomer release found")
    return max(candidates, key=version_key)


def update(tag):
    version_key(tag)
    paths = [ROOT / name for name in (
        "run/action.yml", "push/action.yml", "README.md", "test/test.sh", "test/run.sh")]
    old_versions = set()
    for path in paths[:2]:
        source = path.read_text()
        match = re.search(r"(?m)^  cli-version:\n(?:    .*\n)*?    default: (20\d{2}\.\d{1,2}\.\d{1,2}(?:-beta\.\d+)?)$", source)
        if not match:
            raise ValueError(f"missing cli-version default in {path}")
        old_versions.add(match.group(1))
    if len(old_versions) != 1:
        raise ValueError("run and push action defaults disagree")
    old = old_versions.pop()
    if version_key(tag) < version_key(old):
        raise ValueError(f"refusing to downgrade {old} to {tag}")
    for path in paths:
        source = path.read_text()
        count = source.count(old)
        if count == 0:
            raise ValueError(f"missing old CLI version in {path}")
        path.write_text(source.replace(old, tag))


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "latest":
            print(latest_release(sys.argv[2]))
        elif len(sys.argv) == 3 and sys.argv[1] == "update":
            update(sys.argv[2])
        else:
            raise ValueError("usage: update-doomer-cli.py latest RELEASES.json | update TAG")
    except (ValueError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
