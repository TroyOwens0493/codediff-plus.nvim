#!/usr/bin/env python3
"""Count tracked source lines by responsibility, without counting build output."""

import argparse
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {
    ".lua", ".c", ".h", ".py", ".sh", ".cmd", ".txt", ".md", ".toml",
    ".json", ".jsonc", ".yml", ".yaml", ".in",
}
BUILD_NAMES = {"CMakeLists.txt", "Makefile", "Makefile.win", "VERSION"}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def category(name):
    path = Path(name)
    suffix = path.suffix.lower()
    if suffix not in TEXT_SUFFIXES and path.name not in BUILD_NAMES:
        return None
    if name.startswith("libvscode-diff/vendor/"):
        return "vendor"
    if name.startswith(("tests/", "libvscode-diff/tests/")):
        return "tests"
    if name.startswith(("lua/", "plugin/")) and suffix == ".lua":
        return "production_lua"
    if name.startswith("libvscode-diff/") and suffix in {".c", ".h"}:
        return "production_c"
    if name.startswith(("docs/", "doc/")) or suffix == ".md":
        return "documentation"
    return "build_and_tools"


def measure(ref):
    if ref == "WORKTREE":
        names = git("ls-files", "-c", "-o", "--exclude-standard", "-z")
    else:
        names = git("ls-tree", "-rz", "--name-only", ref)
    totals = {}
    for raw_name in sorted(set(filter(None, names.split(b"\0")))):
        name = raw_name.decode("utf-8", errors="surrogateescape")
        group = category(name)
        if not group:
            continue
        if ref == "WORKTREE":
            path = ROOT / name
            if not path.is_file():
                continue
            content = path.read_bytes()
        else:
            content = git("show", f"{ref}:{name}")
        # Count physical lines. A final newline terminates a line, not an extra one.
        lines = content.split(b"\n") if content else []
        if lines and lines[-1] == b"":
            lines.pop()
        bucket = totals.setdefault(group, {"files": 0, "lines": 0, "nonblank": 0})
        bucket["files"] += 1
        bucket["lines"] += len(lines)
        bucket["nonblank"] += sum(bool(line.strip()) for line in lines)
    return totals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "refs", nargs="*", default=["HEAD", "WORKTREE"],
        help="Git revisions or WORKTREE (default: HEAD WORKTREE)",
    )
    args = parser.parse_args()
    print(json.dumps({ref: measure(ref) for ref in args.refs}, indent=2))


if __name__ == "__main__":
    main()
