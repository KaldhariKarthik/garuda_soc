# G0: Genus hello-world on the Cadence generic 45 nm library.
set_db library /home/install/FOUNDRY/digital/45nm/dig/lib/typical.lib
read_hdl -sv -define SYNTHESIS flow/signoff/g0/hello.sv
elaborate hello
syn_generic
syn_map
report_gates
exit
