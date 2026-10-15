"""The shared riscv-dv test list (tb/core/riscv_dv/testlist), read for pygen."""
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def load_testlist(path=os.path.join(ROOT, "tb", "core", "riscv_dv", "testlist")):
    """name -> (generator test, [pygen options]) from the shared test list."""
    tests = {}
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        name, gen, *opts = line.split()
        tests[name] = (gen, ["--" + o[1:] for o in opts if o.startswith("+")])
    return tests
