# G0: JasperGold FPV hello-world - prove that q follows d one cycle later.
analyze -sv12 +define+SYNTHESIS flow/signoff/g0/hello.sv
elaborate -top hello
clock clk
reset -expression {!rst_n}
assert -name a_q_follows_d {d |=> q}
prove -all
report -summary
exit
