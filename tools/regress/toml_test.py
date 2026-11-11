#!/usr/bin/env python3
"""toml_test.py -- one row of a tb/core/run/<suite>.toml as shell settings for
flow/regress/run_test.sh (1-TOPS G5 5.8, 5.9: every core program in the irun
coverage session, from the same manifest the open flow runs).

    eval "$(python3.12 tools/regress/toml_test.py <suite>__<test>)"

Prints FL, TOP, ARGS and MARK. Settings are taken test first, then [defaults],
then [bench]; the coverage file list (cov_flist) is preferred to flist, so the
core covergroups are bound in. A program row (hex = ...) gets +HEX=<hex>; a row's
`defines` become +define+ options (the halt-timeout variant needs one).
Exit 1, with a message on stderr, if the suite or the test does not exist.
"""
import os, shlex, sys, tomllib

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
spec = sys.argv[1]
suite, sep, name = spec.partition("__")
path = os.path.join(R, "tb", "core", "run", suite + ".toml")
if not sep or not os.path.exists(path):
    sys.exit(f"toml_test.py: no manifest for '{spec}' (expected <suite>__<test>, {path})")
d = tomllib.load(open(path, "rb"))
rows = [t for t in d.get("test", []) if t.get("name") == name]
if len(rows) != 1:
    sys.exit(f"toml_test.py: test '{name}' found {len(rows)} times in {path}")
t, df, b = rows[0], d.get("defaults", {}), d.get("bench", {})


def get(key):
    for src in (t, df, b):
        if key in src:
            return src[key]
    return None


fl = get("cov_flist") or get("flist")
top = get("top")
if not fl or not top:
    sys.exit(f"toml_test.py: '{spec}' has no file list or top")
args = ([f"+define+{x}" for x in (get("defines") or [])] +
        ([f"+HEX={t['hex']}"] if "hex" in t else []) + list(get("plusargs") or []))
print(f"FL={shlex.quote(fl)}")
print(f"TOP={shlex.quote(top)}")
print(f"ARGS={shlex.quote(' '.join(args))}")
print(f"MARK={shlex.quote(get('marker') or 'TOHOST=1 -> PASSED')}")
