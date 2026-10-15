# H8. Mutation and planted defects

The flow lands with plan E11 (hand mutants via the `run_mut.py` pattern, mcy per
module); the definitions are in force now.

| Class | Meaning | Counts as killed |
|---|---|---|
| KILLED-BY-CHECK | a named checker fired: co-simulation mismatch, assertion, scoreboard, formal property | yes |
| KILLED-OTHER | only a timeout or a crash | **no**: gets a checker or an analysis |
| EQUIVALENT | proven equivalent (eqy or an SBY miter) | excluded |
| UNREACHABLE | proven unreachable | excluded |
| TOOL-FAIL | the mutant could not be built or run | excluded, listed |
| SURVIVOR | none of the above | no |

Score per module = KILLED-BY-CHECK / (all - EQUIVALENT - UNREACHABLE - TOOL-FAIL);
target 95%. Every SURVIVOR gets a written analysis and either a new check or a
reasoned acceptance. A control mutant that changes nothing observable proves
nothing (see H2: the first N1 control mutated an `add` whose operands were zero).
