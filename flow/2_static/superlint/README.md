# Superlint by hand

JasperGold Superlint = HAL's structural checks plus formal checks decided by the proof engine
(overflow, array index out of range, divide by zero, unreachable code, overlapping case items,
bus contention). Licence feature `jasper_papp`.

Run from the repository root, in tcsh (after the usual setup, `Docs`: `~/Desktop/garuda_linting_lesson.md`):

```
setenv TOP garuda_pwm_top
setenv FL  rtl/pwm/filelist.f
setenv CLK pclk_i
setenv RST preset_n_i
/home/install/JASPER/bin/jg -allow_unsupported_OS -superlint -batch -no_jges -proj sim/superlint/jgproject flow/2_static/superlint/superlint.tcl
```
In bash use `export TOP=garuda_pwm_top` and so on. Results: `sim/superlint/<TOP>/superlint_report.txt`
and the summary on the terminal. For the window instead of batch, leave out `-batch`.

| Setting | Where to find it |
|---|---|
| `TOP` | the `-top` of the block in `~/Desktop/garuda_cov_every_block.md` |
| `FL` | the RTL file list of the block, `rtl/<dir>/filelist.f` |
| `CLK`, `RST` | the clock and reset ports in the block's `module` header: `grep -nE "input.*(clk|rst)" rtl/<dir>/<top>.v` |
