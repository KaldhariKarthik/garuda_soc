#!/usr/bin/env bash
# Reports which cells of the CORE-SPEC [N-11.2] hold x flush matrix any test
# actually reaches. See Docs/BUGS.md AUD-8.
set -u
D=sim/pipe_matrix; mkdir -p "$D"
xrun -f tb/soc/filelist_boot.f -top tb_boot -xmlibdirname "$D/xcelium.d" \
     -snapshot pmx -l "$D/elab.log" -elaborate > /dev/null 2>&1
grep -qE "^xrun: \*[EF]|^xmelab: \*[EF]" "$D/elab.log" && { echo "ELAB FAILED"; exit 1; }
for h in sw/build/*.hex; do
    t=$(basename "$h" .hex)
    case $t in bootrom|flash|t_chip_*) continue;; esac
    xrun -R -xmlibdirname "$D/xcelium.d" -snapshot pmx -l "$D/$t.log" \
         +HEX="$h" +MAXCYC="${MAXCYC:-200000}" +QUIET +GARUDA_PIPE_MATRIX > /dev/null 2>&1
done
python3 - "$D" <<'PY'
import re, sys, glob
tot = {}
for f in glob.glob(sys.argv[1] + '/*.log'):
    for line in open(f, errors='ignore'):
        if '[PIPE-MATRIX]' not in line: continue
        h = re.search(r'(H\d)', line)
        if not h: continue
        for k, v in re.findall(r'([a-z_\-]+)=(\d+)', line):
            key = "%s %s" % (h.group(1), k)
            tot[key] = tot.get(key, 0) + int(v)
if not tot:
    print("no matrix output - is pipe_ctrl_sva bound and +GARUDA_PIPE_MATRIX set?"); sys.exit(1)
never = [k for k in tot if tot[k] == 0]
print("%-24s %14s" % ("MATRIX CELL", "times reached"))
for k in sorted(tot):
    print("%-24s %14d%s" % (k, tot[k], "   **NEVER**" if tot[k] == 0 else ""))
print("\npipe_matrix: %d of %d observable cells reached; %d never"
      % (len(tot) - len(never), len(tot), len(never)))
PY
