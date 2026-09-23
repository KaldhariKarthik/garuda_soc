#!/usr/bin/env python3
# =============================================================================
# vendor_sync.py -- provenance for the third-party RTL under rtl/third_party/
#
# Every vendored file is recorded in rtl/third_party/MANIFEST.yaml with the
# upstream URL, the exact commit it came from, its SPDX licence and a sha256 of
# the file as vendored. Three commands:
#
#   python3 tools/vendor_sync.py --check    exit 1 if any vendored file differs
#                                           from its recorded hash (CI / review)
#   python3 tools/vendor_sync.py --update   re-hash after a deliberate re-vendor
#   python3 tools/vendor_sync.py --report   print the table for THIRD_PARTY_NOTICES
#
# MANIFEST.yaml is hand-written provenance (url, commit, licence, why we use it).
# HASHES.txt is generated: "<sha256>  <repo-relative path>", sha256sum format,
# so `sha256sum -c rtl/third_party/HASHES.txt` works without this script too.
#
# Why: a silent local edit to upstream code is how a tapeout loses track of what
# it is shipping. Policy (Docs/DECISIONS.md D-22) is that upstream files are
# never edited - deltas live in our wrappers, and the rare unavoidable change
# goes in <ip>/patches/*.patch, which this script applies and records.
# =============================================================================
import argparse
import difflib
import hashlib
import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TP = os.path.join(ROOT, "rtl", "third_party")
MANIFEST = os.path.join(TP, "MANIFEST.yaml")
HASHES = os.path.join(TP, "HASHES.txt")


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def walk_sources(ip_dir):
    """Every vendored source file of one IP, repo-relative, sorted."""
    src = os.path.join(TP, ip_dir, "src")
    out = []
    for dirpath, _, names in os.walk(src):
        for n in sorted(names):
            p = os.path.join(dirpath, n)
            out.append(os.path.relpath(p, ROOT))
    return sorted(out)


# -----------------------------------------------------------------------------
# Patches (D-22). Upstream files are normally byte-identical to what was
# vendored. Where that is impossible - a defect in the IP that cannot be worked
# around in a GARUDA wrapper - the pristine file is snapshotted under
# <ip>/patches/orig/ and the delta is recorded as <ip>/patches/*.patch.
#
# The patch file is documentation AND the check: --check regenerates the diff
# from orig/ against the working file and fails unless it matches what is
# recorded. So editing a vendored file without running --update fails, and so
# does editing the pristine snapshot. No `patch` binary is needed.
# -----------------------------------------------------------------------------

def patched_files(ip_dir):
    """(pristine, working, repo-relative) for every file with a snapshot."""
    orig_root = os.path.join(TP, ip_dir, "patches", "orig")
    out = []
    for dirpath, _, names in os.walk(orig_root):
        for n in sorted(names):
            o = os.path.join(dirpath, n)
            rel = os.path.relpath(o, orig_root)
            c = os.path.join(TP, ip_dir, rel)
            out.append((o, c, os.path.relpath(c, ROOT)))
    return sorted(out, key=lambda t: t[2])


def make_diff(ip_dir):
    chunks = []
    for o, c, rel in patched_files(ip_dir):
        if not os.path.exists(c):
            return None
        a = open(o).read().splitlines(keepends=True)
        b = open(c).read().splitlines(keepends=True)
        chunks.append("".join(difflib.unified_diff(
            a, b, fromfile="a/" + rel, tofile="b/" + rel, n=3)))
    return "".join(chunks)


def patch_paths(ip_dir):
    d = os.path.join(TP, ip_dir, "patches")
    if not os.path.isdir(d):
        return []
    return sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".patch"))


def strip_header(text):
    """Everything before the first diff hunk is prose, and is not compared."""
    i = text.find("--- a/")
    return text[i:] if i >= 0 else text


def stored_diff(ip_dir):
    return "".join(strip_header(open(f).read()) for f in patch_paths(ip_dir))


def load():
    with open(MANIFEST) as f:
        return yaml.safe_load(f)


def read_hashes():
    if not os.path.exists(HASHES):
        return {}
    out = {}
    for line in open(HASHES):
        line = line.strip()
        if line and not line.startswith("#"):
            h, p = line.split(None, 1)
            out[p.strip()] = h
    return out


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--update", action="store_true")
    g.add_argument("--report", action="store_true")
    args = ap.parse_args()

    man = load()
    recorded = read_hashes()
    found = []
    for ip in man["ips"]:
        found += walk_sources(ip["dir"])

    if args.update:
        with open(HASHES, "w") as f:
            f.write("# GENERATED by tools/vendor_sync.py --update - sha256sum format\n")
            f.write("# Provenance (url, commit, licence) is in MANIFEST.yaml.\n")
            f.write("# Files listed under an IP with a patches/ directory are the\n")
            f.write("# PATCHED versions; patches/orig/ holds what was vendored.\n")
            for p in found:
                f.write("%s  %s\n" % (sha256(os.path.join(ROOT, p)), p))
        print("HASHES.txt: %d files" % len(found))
        for ip in man["ips"]:
            if not patched_files(ip["dir"]):
                continue
            paths = patch_paths(ip["dir"])
            if len(paths) > 1:
                print("%s: %d patch files - regenerate them by hand, this tool "
                      "will not guess how to split the diff" % (ip["name"], len(paths)))
                continue
            target = paths[0] if paths else os.path.join(
                TP, ip["dir"], "patches", "0001-garuda-changes.patch")
            head = ""
            if paths:
                existing = open(target).read()
                i = existing.find("--- a/")
                head = existing[:i] if i > 0 else ""
            with open(target, "w") as f:
                f.write(head)
                f.write(make_diff(ip["dir"]))
            print("%s: patch regenerated -> %s" %
                  (ip["name"], os.path.relpath(target, ROOT)))
        return 0

    if args.report:
        print("| IP | Upstream | Commit | Licence | Files |")
        print("|---|---|---|---|---|")
        for ip in man["ips"]:
            n = len(walk_sources(ip["dir"]))
            np = len(patched_files(ip["dir"]))
            mod = " **%d modified**" % np if np else ""
            print("| `%s` | %s | `%s` | %s | %d%s |" %
                  (ip["name"], ip["upstream"], ip["commit"][:12], ip["spdx"], n, mod))
        return 0

    bad = missing = 0
    for p in found:
        if p not in recorded:
            print("UNRECORDED: %s (vendored but not hashed)" % p)
            missing += 1
        elif sha256(os.path.join(ROOT, p)) != recorded[p]:
            print("MODIFIED: %s" % p)
            print("   upstream files are never edited - put the delta in a wrapper,")
            print("   or in <ip>/patches/ with a Docs/BUGS.md entry (D-22)")
            bad += 1
    for p in recorded:
        if not os.path.exists(os.path.join(ROOT, p)):
            print("MISSING: %s" % p)
            missing += 1

    # Every patched IP must still be exactly orig/ + the recorded patch.
    npatched = 0
    for ip in man["ips"]:
        pf = patched_files(ip["dir"])
        if not pf:
            continue
        npatched += len(pf)
        if not patch_paths(ip["dir"]):
            print("NO PATCH FILE: %s has patches/orig/ but no *.patch (D-22)" % ip["name"])
            bad += 1
            continue
        if make_diff(ip["dir"]) != stored_diff(ip["dir"]):
            print("PATCH DRIFT: %s" % ip["name"])
            print("   the working files no longer match patches/orig/ + patches/*.patch.")
            print("   Run --update if the change was deliberate, and update Docs/BUGS.md.")
            bad += 1

    if bad or missing:
        print("\nvendor_sync: %d modified, %d missing/unrecorded" % (bad, missing))
        return 1
    print("vendor_sync: %d files across %d IPs match HASHES.txt"
          % (len(found), len(man["ips"])))
    if npatched:
        print("vendor_sync: %d file(s) carry a recorded GARUDA patch, and match it"
              % npatched)
    return 0


if __name__ == "__main__":
    sys.exit(main())
