# Design_Docs — which file is the specification?

**The `.md` is normative. The `.docx` is an export.**

Where a `.md` and a `.docx` disagree, the `.md` wins, and the `.docx` is a bug.

## Why this needed saying

Most specifications here exist twice, as `GARUDA-X-SPEC-001.md` and
`GARUDA-X-SPEC-001.docx`, **with no generator between them** — the Word files
were produced by hand. Two hand-maintained sources of truth is not a
documentation style, it is a defect generator, and it has already produced one:

> **AUD-2** (`Docs/BUGS.md` §1d). The AHB2APB window table numbered its rows
> from 0 while the hardware numbers windows from 1 — window *n* sits at
> `0x4000_0000 + 0x1000 x n`, decoded as `haddr[15:12]`. Four specifications
> inherited the off-by-one, so `GARUDA-CLIC-SPEC-001` told a reader to program
> window 9, which is `reset_ctrl`'s. Every base address in every document was
> correct throughout; only the index was wrong, and nothing executed it, so
> nothing caught it.

## The rule

1. **Edit the `.md`.** Never edit a `.docx` directly; the next regeneration
   discards it.
2. **Regenerate before circulating**, with `make docs`.
3. **`make check_docs` fails** if any `.docx` is older than its `.md`, by git
   commit date rather than filesystem mtime so a fresh clone gives the same
   answer. Run it before sending anything to a reviewer.

## Current state

`make check_docs` prints the table. As of the 2026-09-26 audit, **seven
`.docx` are stale** (AHB2APB, CLIC, CLKRST, DMA, MEM, PHYS, TIMERS — all of
them corrected in `.md` by that audit) and **five specifications have no
`.docx` at all**: SPIM, I2C, UART, GPIO, PWM, the five peripherals added on
2026-09-22/23.

So a reviewer working from Word today would be reading the window-numbering
error the audit fixed, and would have no document at all for five of the
twenty-two blocks.

**Pandoc is not installed on the simulation host**, which is why the exports
were not regenerated as part of that audit. `make docs` will do it on a machine
that has it:

```sh
pandoc -f gfm -t docx -o Design_Docs/GARUDA-X-SPEC-001.docx \
                         Design_Docs/GARUDA-X-SPEC-001.md
```

## The alternative, if that is a nuisance

Delete the `.docx` and circulate the `.md` — GitHub renders it, it diffs
properly in review, and it cannot drift from itself. The only reason to keep
Word files is that someone downstream requires the format. If nobody does,
deleting them removes the failure mode rather than monitoring it.
