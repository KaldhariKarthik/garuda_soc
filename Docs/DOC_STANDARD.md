# GARUDA documentation standard

Version 1.0, 2026-10-21. This standard applies to every new document and to every new
section of a document in `Docs/`, `flow/` and the track registers. It is based on
ASD-STE100 (Simplified Technical English). We use the main STE rules, not all of them.
Section 3 gives the exceptions.

A reviewer checks a document against the checklist in section 6. A document that does not
follow this standard is a change asked for in the review record (`flow/reviews/TEMPLATE.md`).

## 1. Where documents go

`Docs/README.md` shows each folder and what goes in it. Obey these rules:

1. Put a defect in its track register: `Docs/bugs/track_a.md` or `Docs/bugs/track_b.md`.
2. Do not add entries to `Docs/bugs/archive/BUGS_HISTORY.md`. It is history.
3. Put a ruling in `Docs/DECISIONS.md`, one ruling for each section.
4. Put a dated log in `Docs/logs/<area>/`. Use the name `<AREA>_LOG_<YYYY-MM-DD>.md`.
5. Put a how-to document in `Docs/guides/`.
6. Do not put a new file in the `Docs/` root. Only `README.md`, `DOC_STANDARD.md`,
   `DECISIONS.md`, `COVERAGE.md` and `THIRD_PARTY_NOTICES.md` are there.
7. Write a path from the repository root, for example `Docs/guides/HOWTO_RUN.md`.

## 2. Writing rules (from ASD-STE100)

### 2.1 Words

1. Use simple, common words. Use one word for one meaning.
   Write "start", not "initiate". Write "use", not "utilise".
2. Use the same term for the same thing in all of the document. If the text says
   "hclk", do not also write "the bus clock" for it.
3. Use a verb for an action. Write "the tool checks the file", not "the tool does a
   check of the file".
4. Do not use slang, jokes or emotional words.
5. Give the meaning of an abbreviation when you first use it, or use one from section 7.

### 2.2 Sentences

1. Keep a sentence short. Use no more than 20 words for an instruction and no more than
   25 words for a description.
2. Write one instruction in each sentence. You can write two actions in one sentence only
   if you do them at the same time.
3. Use the active voice. Write "Yosys removes the latch", not "the latch is removed".
4. Write an instruction as a command. Write "Run `make check_tree`", not "You should
   run `make check_tree`".
5. Do not leave out words such as "the", "a" and "is" to make text shorter.
6. Write "do not" clearly. Do not hide a prohibition in a long sentence.

### 2.3 Paragraphs and structure

1. Write one topic in each paragraph. Use no more than six sentences in a paragraph.
2. Start with the most important information.
3. Use a numbered list for steps that you must do in sequence.
4. Use a table for items that have the same properties.
5. Put a warning or a caution before the step it applies to, not after.

### 2.4 Numbers, units and dates

1. Write a number with its unit: 2000 ps, 320 × 300 µm, 8.65 GiB.
2. Write a date as YYYY-MM-DD.
3. Write a result with the number: "0 violations", not "clean".

## 3. Exceptions (the parts of STE that we do not use)

1. Technical names are permitted: tool names, signal names, cell names, file names and
   commands. Put code, paths and identifiers in backticks.
2. Quote a tool message exactly, in backticks, also if it breaks the rules above.
3. A log can use the past tense to tell what was done.
4. A specification in `Design_Docs/` keeps its own template. This standard applies to its
   new text only.
5. Do not rewrite a dated log or an archived file to obey this standard. Those files are
   records of what was written on a date.

## 4. Defect entries

A defect entry is one row in the "New entries" table of its track register.

| Column | Rule |
|---|---|
| ID | The next free ID of the track. Block prefix (for example `DMA-20`) or a prefix with the track letter (for example `TOOL-B8`). Put the ID in bold: `**TOOL-B8**`. Do not reuse or renumber an ID. |
| Where | The file or the block, in backticks. |
| Status | One word: `OPEN`, `FIXED`, `WAIVED`, `SPEC` or `DONE`, then the date. |
| Priority | P1, P2 or P3 (track register, "How entries are numbered"). |
| Summary | First a bold sentence that tells what is wrong. Then the cause, the fix, and the test that fails without the fix. |
| Found by | The method that found it, for example "JasperGold" or "chip simulation". |

Before you add an ID, search both track registers and the archive for it:
`git grep -n "<ID>" Docs/bugs/`. Then run `make check_tree`. It fails when an ID has two
definitions.

## 5. Logs and decisions

1. A log starts with the date, the scope, and the commit or run that it records.
2. A log gives the command and its result. It tells what was not done.
3. A decision gives the question, the ruling, who decided, the date and the reason.

## 6. Review checklist

| # | Check |
|---|---|
| 1 | The file is in the correct folder (section 1). |
| 2 | Each instruction is a command, one in each sentence. |
| 3 | Sentences are no longer than 20 words (instructions) or 25 words (descriptions). |
| 4 | The text uses the active voice, except for a quoted tool message. |
| 5 | Each term has one meaning, and the same term is used each time. |
| 6 | Numbers have units. Dates are YYYY-MM-DD. |
| 7 | A defect entry has all six columns, and `make check_tree` passes. |

## 7. Approved abbreviations

| Abbreviation | Meaning |
|---|---|
| CTS | Clock tree synthesis |
| DFT | Design for test |
| DRC | Design rule check |
| GDS | The layout file sent to the foundry (GDSII) |
| LEC | Logical equivalence check |
| LVS | Layout versus schematic |
| PD | Physical design |
| PDK | Process design kit |
| RTL | Register-transfer level (the Verilog source) |
| SDC | Timing constraints file (Synopsys Design Constraints) |
| STA | Static timing analysis |
| WNS, TNS | Worst negative slack, total negative slack |
