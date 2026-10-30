#!/usr/bin/env python3
"""Auto-generate release notes (or a whole CHANGELOG.md) from git history.

Commits are grouped by their conventional prefix (feat:, fix:, docs:, ...);
commits without a prefix land under "Changes".

Usage:
    tools/release-notes.py v1.0.3        # release notes for one tag/ref
    tools/release-notes.py --changelog   # regenerate CHANGELOG.md content
"""
import re
import subprocess
import sys

def git(*args):
    return subprocess.check_output(["git"] + list(args), text=True).strip()

REPO_URL = re.sub(r"\.git$", "", git("remote", "get-url", "origin"))
REPO_URL = REPO_URL.replace("git@github.com:", "https://github.com/")

GROUPS = [
    ("Features", ("feat",)),
    ("Fixes", ("fix",)),
    ("Performance", ("perf",)),
    ("Refactoring", ("refactor",)),
    ("Documentation", ("docs",)),
    ("Tests", ("test", "tests")),
    ("Build & CI", ("build", "ci")),
]
PREFIX_RE = re.compile(r"^(\w+)(\([^)]*\))?!?:\s+")

def commit_group(subject):
    m = PREFIX_RE.match(subject)
    if not m:
        return "Changes"
    prefix = m.group(1).lower()
    for title, prefixes in GROUPS:
        if prefix in prefixes:
            return title
    return "Changes"

def clean_subject(subject):
    return PREFIX_RE.sub("", subject)

def commits(ref_range):
    out = git("log", "--reverse", "--pretty=format:%s\x1f%h", *ref_range)
    return [tuple(line.split("\x1f")) for line in out.splitlines() if line]

def notes_for(ref):
    """Release notes for one tag/commit: everything since the previous tag."""
    prev = None
    try:
        prev = git("describe", "--tags", "--abbrev=0", ref + "^")
    except subprocess.CalledProcessError:
        pass
    rev_range = [ref] if prev is None else ["%s..%s" % (prev, ref)]
    groups = {}
    for subject, sha in commits(rev_range):
        groups.setdefault(commit_group(subject), []).append(
            "- %s (%s)" % (clean_subject(subject), sha))

    lines = []
    for title, _ in GROUPS + [("Changes", ())]:
        if groups.get(title):
            lines.append("### %s" % title)
            lines.extend(groups[title])
            lines.append("")
    if prev:
        lines.append("**Full changelog**: %s/compare/%s...%s" % (REPO_URL, prev, ref))
    else:
        lines.append("**Full changelog**: %s" % REPO_URL)
    return "\n".join(lines).strip()

def changelog():
    tags = git("tag", "--list", "v*", "--sort=-v:refname").splitlines()
    out = ["# Changelog", "",
           "All notable changes to this project, generated from git history by",
           "`make changelog` — do not edit by hand.", ""]
    for tag in tags:
        date = git("log", "-1", "--format=%as", tag)
        out.append("## [%s] - %s" % (tag.lstrip("v"), date))
        out.append("")
        out.append(notes_for(tag))
        out.append("")
    return "\n".join(out).strip() + "\n"

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: release-notes.py <tag-or-ref> | --changelog")
    print(changelog() if sys.argv[1] == "--changelog" else notes_for(sys.argv[1]))
