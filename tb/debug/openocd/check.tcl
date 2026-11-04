# The G7 checks, in OpenOCD's own Tcl; every line says PASS or FAIL. Run after garuda_sim.cfg.
proc say {ok what} { if {$ok} { echo "OCD PASS $what" } else { echo "OCD FAIL $what" } }
set ok_init [expr {![catch {init} e]}]
say $ok_init "init (scan chain and the target examine): [expr {$ok_init ? {} : $e}]"
set id [irscan garuda.cpu 0x01]
set id [drscan garuda.cpu 32 0]
say [expr {"0x$id" == "0x00000db1" || $id == "00000db1"}] "IDCODE over the real TAP = $id"
irscan garuda.cpu 0x11
if {[catch {set st [riscv dmi_read 0x11]} e]} { say 0 "dmstatus read: $e" } else { say [expr {($st & 0xf) == 2}] "dmstatus = $st (version 2)" }
# a 64-word image over SBA, then verify it, then read a word back
# IMG: a 64-word little-endian image, word i = i * 0x9E3779B1 (made by run_ocd.sh; Jim Tcl has
# no `binary` command)
if {[catch {load_image $IMG 0x400 bin} e]} { say 0 "load_image over SBA: $e" } else { say 1 "load_image over SBA (64 words to ISRAM 0x400)" }
if {[catch {verify_image $IMG 0x400 bin} e]} { say 0 "verify_image: $e" } else { say 1 "verify_image: the 64 words read back over SBA" }
if {[catch {set w [read_memory 0x404 32 1]} e]} { say 0 "read_memory 0x404: $e" } else { say [expr {$w == 0x9e3779b1}] "read_memory 0x404 = $w" }
if {[catch {reset halt} e]} { say 0 "reset halt: $e" } else { say 1 "reset halt" }
if {[catch {resume} e]} { say 0 "resume: $e" } else { say 1 "resume" }
# run_ocd.sh needs this line: without it a script that stopped early would look clean
echo "OCD DONE"
shutdown
