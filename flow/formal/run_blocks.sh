#!/usr/bin/env bash
# run_blocks.sh [name ...] - prove the bound properties of the blocks below with
# flow/formal/block_fpv.tcl and write flow/formal/<name>/<name>_fpv.result.txt.
# Each line: name | top | file list | clocks | resets | children of the top | extra environment
cd "$(dirname "$0")/../.."
JG=/home/install/JASPER/bin/jg
TABLE='
clic    |clic_top        |rtl/clic/filelist.f        |hclk_i pclk_i:2 |hreset_n_i preset_n_i |clic_apb clic_select|APB=pclk_i
timers  |timers_top      |rtl/timers/filelist.f      |hclk_i pclk_i:2 |hreset_n_i preset_n_i ext_rst_n_i |mtime timers_apb wdt|APB=pclk_i
reset   |reset_ctrl      |rtl/reset_ctrl/filelist.f  |hclk_i aon_clk_i pclk_i:2 |ext_rst_n_i |reset_ctrl_apb|DEFS=FORMAL APB=pclk_i APBRST=preset_n_o
pwm     |garuda_pwm_top  |rtl/pwm/filelist.f         |pclk_i          |preset_n_i |garuda_pwm_core|APB=pclk_i
gpio    |garuda_gpio_top |rtl/gpio/filelist.f        |pclk_i          |preset_n_i ||APB=pclk_i
i2c     |garuda_i2c_top  |rtl/i2c/filelist.f         |pclk_i          |preset_n_i ||APB=pclk_i
spis    |garuda_spis_top |rtl/spi_slave/filelist.f   |pclk_i          |preset_n_i |garuda_spis_core|APB=pclk_i
shim    |garuda_apb_shim |rtl/common/filelist_shim_fv.f |pclk_i       |preset_n_i ||APB=pclk_i
if_id   |if_id           |rtl/core/filelist_pipe_regs_fv.f |clk_i   |rst_n_i ||
id_ex   |id_ex           |rtl/core/filelist_pipe_regs_fv.f |clk_i   |rst_n_i ||
ex_mem  |ex_mem          |rtl/core/filelist_pipe_regs_fv.f |clk_i   |rst_n_i ||
clic_ctrl |clic_ctrl     |rtl/core/filelist_clic_ctrl_fv.f |clk_dummy |rst_dummy ||COMB=1
d_port  |d_port_ahb_master |rtl/core/filelist_d_port_ahb_master_fv.f |clk_i |rst_n_i ||
csr_file |csr_file       |rtl/core/filelist_csr_file_fv.f |clk_i      |rst_n_i ||
regfile |regfile         |rtl/core/filelist_regfile_fv.f |clk_i       |rst_n_i ||
branch_unit |branch_unit  |rtl/core/filelist_branch_unit_fv.f |c |r ||COMB=1
forward_unit |forward_unit |rtl/core/filelist_forward_unit_fv.f |c |r ||COMB=1
hazard_forward_unit |hazard_forward_unit |rtl/core/filelist_hazard_forward_unit_fv.f |c |r ||COMB=1
load_store_unit |load_store_unit |rtl/core/filelist_load_store_unit_fv.f |c |r ||COMB=1
pc_gen  |garuda_pc_gen   |rtl/core/filelist_garuda_pc_gen_fv.f |clk_i |rst_n_i ||
prefetch |garuda_prefetch_buffer |rtl/core/filelist_garuda_prefetch_buffer_fv.f |clk_i |rst_n_i ||
trap_ctrl |trap_ctrl     |rtl/core/filelist_trap_ctrl_fv.f |clk_i |rst_n_i ||
branch_predict |branch_predict |rtl/core/filelist_branch_predict_fv.f |c |r ||COMB=1
csr_rw  |csr_rw          |rtl/core/filelist_csr_rw_fv.f |c |r ||COMB=1
if_stage |garuda_if_stage_top |rtl/core/filelist_if_stage_fv.f |clk_i |rst_n_i |garuda_pc_gen garuda_iport_ahb_master garuda_prefetch_buffer|ASSUMES_FILE=flow/formal/core/if_stage_assumes.txt
decode  |decode_control  |rtl/core/filelist_decode_fv.f |c |r ||COMB=1
dsu     |dsu_top         |rtl/dsu/filelist.f         |clk             |rst_n |dsu_decoder dsu_stall overflow_flag mac_cluster operand_router readback_mux result_selector barrel_shifter|
'
want=" $* "
echo "$TABLE" | while IFS='|' read -r name top fl clks rsts kids extra; do
    name=$(echo $name); [ -z "$name" ] && continue
    [ -n "$*" ] && [[ "$want" != *" $name "* ]] && continue
    top=$(echo $top); fl=$(echo $fl); kids=$(echo $kids)
    mkdir -p flow/formal/$name sim/formal_$name
    ( [ -n "$extra" ] && eval "export $extra"
      TOP=$top FL=$fl CLKS="$clks" RSTS="$rsts" PROPS=sim/formal_$name/props.txt \
        timeout 1500 $JG -allow_unsupported_OS -fpv -batch -no_jges -proj sim/formal_$name/jgproject \
        flow/formal/block_fpv.tcl > sim/formal_$name/run.log 2>&1 )
    if [ ! -s sim/formal_$name/props.txt ]; then
        echo "$name: NO RESULT ($(grep -m1 -E '^ERROR' sim/formal_$name/run.log))"; continue
    fi
    na=$(awk '$2=="assert"' sim/formal_$name/props.txt | wc -l)
    np=$(awk '$2=="assert" && $1=="proven"' sim/formal_$name/props.txt | wc -l)
    other=$(awk '$2=="assert" && $1!="proven"{print $1, $3}' sim/formal_$name/props.txt | sed 's/<embedded>:://')
    ncov=$(awk '$2=="cover"' sim/formal_$name/props.txt | wc -l)
    nunr=$(awk '$2=="cover" && $1!="covered"' sim/formal_$name/props.txt | wc -l)
    { echo "top: $top"; echo "children: $kids"; echo "script: flow/formal/block_fpv.tcl (flow/formal/run_blocks.sh $name)"
      echo "proved: $np/$na"; echo "tool: JasperGold Apps 2022.09p002, $(date +%Y-%m-%d)"; echo
      echo "clocks: $clks   resets: $rsts"
      echo "covers: $ncov, not covered: $nunr"
      [ -n "$other" ] && { echo "assertions not proved:"; echo "$other" | sed 's/^/  /'; }
      awk '$2=="cover" && $1!="covered"{print "  cover " $1 ": " $3}' sim/formal_$name/props.txt | sed 's/<embedded>:://'
    } > flow/formal/$name/${name}_fpv.result.txt
    echo "$name: $np/$na proved, $nunr of $ncov covers not reached"
done
