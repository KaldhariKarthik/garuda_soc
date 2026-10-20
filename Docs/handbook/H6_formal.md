# H6. Formal: result classes, assumptions, replay

Tools: SymbiYosys + Yosys (yosys-slang) + ABC (pdr) + yices/bitwuzla, until the
JasperGold licence; every result is re-run on Jasper later. The core formal setup
moves into `tb/core/formal/` with plan P0.9.

## Result classes (exactly one per property)
| Class | Meaning |
|---|---|
| PROVEN | unbounded proof (PDR or k-induction) |
| BOUNDED(depth) | no counterexample up to `depth` cycles from reset; **not a proof** |
| COVERED | a cover property was reached (non-vacuity) |
| VACUOUS | the antecedent can never happen: a finding, not a pass |
| UNRESOLVED | no result (timeout, solver limit) |

PROVEN and BOUNDED are never counted together. A BOUNDED result on a
sign-off-critical property needs written approval by both track owners, with the
depth justified by covers showing the relevant scenario fits inside it.
A PDR FAIL without a trace is reported by SBY as `ERROR rc=16`: the formal verdict
reads the engine summary line, never only the status word.

## Assumption register
`tb/<blk>/formal/ASSUMPTIONS.md` lists every assumption of every harness (reset
sequence, bus fairness bound K, abstractions such as a DSU stub or a clock-gate
pass-through, cut points), each with its justification and the simulation check
that backs it. A proof is only as good as the assumptions listed next to it.

## Counterexamples
Every meaningful counterexample is replayed in simulation (trace -> stimulus)
before it is filed as a bug; the replay log is the bug's evidence.

## Mutants against properties
Each property set is checked against planted mutants (H8): a property set that a
known-bad design still satisfies is too weak.
