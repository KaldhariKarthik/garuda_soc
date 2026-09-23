// Vendored upstream files carry no `timescale directive, and we do not edit
// them (D-22). Xcelium accepts -timescale ONCE per elaboration, so it lives
// here and every TOP-LEVEL filelist includes this file exactly once. Per-IP
// filelists must not repeat it: two IPs in one elaboration would then pass
// -timescale twice and xrun fails with *E,OPTNOML.
-timescale 1ns/1ps
