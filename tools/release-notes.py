#!/usr/bin/env python3
"""Print the CHANGELOG.md section for one version.

Usage: tools/release-notes.py v1.0.0   (a leading "v" is optional)
"""
import re
import sys

if len(sys.argv) != 2:
    sys.exit("usage: release-notes.py <version>")
version = sys.argv[1]
if version.startswith("v"):
    version = version[1:]

text = open("CHANGELOG.md", encoding="utf-8").read()
m = re.search(
    r"^## \[%s\][ \t]*-[ \t]*(\S+)[ \t]*\n(.*?)(?=^## \[|\Z)" % re.escape(version),
    text,
    re.M | re.S,
)
if not m:
    sys.exit("CHANGELOG.md has no entry for version %s" % version)

print("Changes in v%s (%s)\n" % (version, m.group(1)))
print(m.group(2).strip())
