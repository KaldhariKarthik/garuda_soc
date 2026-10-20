#!/bin/bash
# TOOL-25 reproducer: Verilator 5.052 --coverage-expr. Prints the expression rows of
# each case. repro_fails.v loses its "=> 1" rows; the two _ok variants count them.
cd "$(dirname "$0")"
for f in repro_fails.v repro_ok_arbiter_no_begin.v repro_ok_no_operand_rewrite.v; do
  rm -rf obj_dir coverage.dat
  verilator --binary --coverage-expr -Wno-fatal "$f" --top tb2 -o sim >/dev/null 2>&1 && ./obj_dir/sim >/dev/null
  echo "== $f"
  python3 -c "
for ln in open('coverage.dat',errors='replace'):
    if not ln.startswith(\"C '\"): continue
    body,c=ln.rstrip('\n').rsplit(\"' \",1)
    kv=dict(x.split('\x02',1) for x in body[3:].split('\x01') if '\x02' in x)
    if kv.get('page','').startswith('v_expr'): print('  ',c, kv.get('o'))"
done
rm -rf obj_dir coverage.dat
