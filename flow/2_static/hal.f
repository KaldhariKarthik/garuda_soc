// HAL options for GARUDA: rtl/soc/filelist_chip.f, top garuda_chip_top.
//   irun -hal -64bit -f rtl/soc/filelist_chip.f -top garuda_chip_top -define SYNTHESIS \
//        -nclibdirname sim/static/INCA_libs -l sim/static/hal.log -f flow/2_static/hal.f
//
// Rules switched off here are formatting, naming and house-style rules that
// carry no functional meaning for this code base. Everything that can hide a
// defect stays on: widths, connectivity, drivers, latches, resets, clocks,
// clock domains, FSM reachability, synthesis and DFT rules.
-halargs "
 -nocheck STYVAL -nocheck MAXLEN -nocheck SEPLIN -nocheck CTLCHR -nocheck NOBLKN
 -nocheck LCVARN -nocheck UCCONN -nocheck DIFCLK -nocheck IDLENG -nocheck PRTCNT
 -nocheck DECLIN -nocheck ALOWID -nocheck KEYWOD -nocheck NUMSUF -nocheck CDWARN
 -nocheck CDNOTE -nocheck SYNPRT -nocheck NBGEND -nocheck USEPRT -nocheck LRGOPR
 -nocheck OLDALW -nocheck BITUNS -nocheck REVROP -nocheck PRMBSE -nocheck PRMVAL
 -nocheck TSETGV -nocheck TUSEGV -nocheck POIASG -nocheck ONPNSG -nocheck IPRTEX
 -nocheck EXPIPC -nocheck IGNDLY -nocheck EMPSTM -nocheck EMPBLK -nocheck MPCMPE
 -nocheck PRMEXP -nocheck USEPAR -nocheck INDXOP -nocheck SHFTNC -nocheck TRNMBT
 -nocheck EXTFSM -nocheck BADFSM -nocheck FFASRT -nocheck INFNOT -nocheck CLKINF
 -nocheck FSMIDN -nocheck NUMDFF -nocheck MXFNOT -nocheck PADMSB -nocheck TRUNCZ
 -nocheck TROPCZ -nocheck CNSTLT -nocheck MICAWS -nocheck IFSMCD -nocheck REDOPR
 -nocheck RDOPND -nocheck VLGMEM -nocheck MEMSIZ -nocheck LOOPTM -nocheck SLNOTP
 -nocheck CBPAHI -nocheck FDTHRU -nocheck SYNASN -nocheck DALIAS -nocheck TPOUNR
"
