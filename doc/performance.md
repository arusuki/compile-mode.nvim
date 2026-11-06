# Issue-driven tests and performance baseline

This historical baseline is retained for comparison. See the subsequent
[optimization report](optimization.md) for implemented repairs and new measurements.

Recorded on 2026-11-07 (Asia/Shanghai), after the module refactor. This work adds
reproducers and measurements; it does not change runtime algorithms or repair the
reported defects. The baseline is commit `c3d4df9` plus the uncommitted refactor.
Each result file includes a source fingerprint so this is not mistaken for a
measurement of the unmodified upstream commit.

## Reproduce the checks

Use Neovim, Python 3, Plenary, and Baleia v1.3.0. The scripts do not download
anything or load your Neovim configuration. From the repository root:

```sh
export PLENARY_PATH=/path/to/plenary.nvim
export BALEIA_PATH=/path/to/baleia.nvim
make issues
make bench
```

Dependency paths default to sibling checkouts, the standard Lazy installation,
or vim-plug. Explicit paths are preferable for reproducibility. `NVIM` can select
another Neovim executable. Results default to ignored `.measurements/*.json`.

```sh
# One reproducer; unresolved behavior deliberately returns a nonzero exit status.
make issues CHECK_ARGS='--cases directory_quickfix'

# A smaller benchmark run, or one scenario at the normal size.
make bench CHECK_ARGS='--sizes 100,1000 --samples 3'
make bench CHECK_ARGS='--cases end_to_end/plain/10000 --output /tmp/plain.json'
```

Every case runs in a fresh Neovim process, with a 60-second outer timeout and
bounded producers. The lifecycle helper waits at most 15 seconds for completion.
`make issues` asserts the intended behavior: failures are visible, not skipped
or converted into passing assertions about a known bug. `make bench` validates
its fixtures and exits nonzero for a functional failure/timeout; it does not set
machine-dependent timing gates. Keep running the ordinary `make test` suite too.

Implementation: `scripts/issues.lua` contains behavior probes;
`scripts/benchmark.lua` contains stage benchmarks and end-to-end measurements;
`scripts/run_checks.py` provides isolation, timeouts, metadata, and JSON output.
`scripts/producer.lua` emits finite reproducible logs without requiring a compiler.

## Issue coverage and functional results

The initial search returned 58 issues. Selected issue metadata is saved in
[issue-sources.json](measurements/issue-sources.json). Issues and their discussion
were reviewed, including closed reports and the earlier performance proposal
[PR #62](https://github.com/ej-shafran/compile-mode.nvim/pull/62).

The [functional result file](measurements/issues-macos-arm64.json) contains
**16 probes: 8 passed, 8 failed**. The existing Plenary suite remains **152 passed,
0 failed**. The extra probes identify gaps in that suite, rather than implying
that its passing results establish these behaviors.

| Source | Probe(s) | Observed result |
| --- | --- | --- |
| [#160](https://github.com/ej-shafran/compile-mode.nvim/issues/160), open | `scroll_filter`, `scroll_render` | **Fail:** while the child is still running, 106 buffer lines exist but the cursor remains on line 5. The existing autoscroll suite only checks after completion. |
| [#159](https://github.com/ej-shafran/compile-mode.nvim/issues/159), closed | `directory_quickfix`, `directory_diagnostics` | **Fail:** an error on output line 6 with source row 1 resolves to the root instead of `build/`; diagnostics omit the intended source buffer. This deliberately distinguishes source and output coordinates. |
| [#136](https://github.com/ej-shafran/compile-mode.nvim/issues/136), open | `highlight_scope` | **Fail:** two compilation-directory window matches remain after returning to the source buffer. |
| [#149](https://github.com/ej-shafran/compile-mode.nvim/issues/149), closed | `nul_streams` | Pass: NULs in both stdout and stderr are removed without corrupting line writes. |
| [#135](https://github.com/ej-shafran/compile-mode.nvim/issues/135), closed; [#76](https://github.com/ej-shafran/compile-mode.nvim/issues/76) discussion | `ansi_cargo` | Pass for a synthetic Cargo-like producer: colored compiler stderr and program stdout survive without escape bytes. Cross-pipe ordering is intentionally not asserted. |
| [#153](https://github.com/ej-shafran/compile-mode.nvim/issues/153), closed | `ansi_underline` | Pass: SGR 4 produces actual underline highlight metadata with Baleia v1.3.0. |
| [#142](https://github.com/ej-shafran/compile-mode.nvim/issues/142), closed | `matcher_priority` | Pass: the documented `priority = 2` selects the custom Zig matcher and preserves row/column captures. |
| [#156](https://github.com/ej-shafran/compile-mode.nvim/issues/156), closed | `quickfix_threshold` | Pass: the warning threshold retains warnings/errors and excludes notes. |
| [#56](https://github.com/ej-shafran/compile-mode.nvim/issues/56), closed | `max_lines` | Pass: 10,000 produced lines with a budget of 100 stop the process, retain bounded output, and report code 143. This does not establish responsiveness without a limit. |
| [#139](https://github.com/ej-shafran/compile-mode.nvim/issues/139), closed | `window_reuse` | Pass: jumping from the compilation window reuses the existing source window. |
| [PR #62](https://github.com/ej-shafran/compile-mode.nvim/pull/62), optimization guard | `mixed_matcher_languages` | Pass: one stream can contain GNU, Python and CMake errors. Optimizations must preserve all three. |
| Related to incremental parsing / [#119](https://github.com/ej-shafran/compile-mode.nvim/issues/119) | `reparse_extmarks`, `reparse_stale_error` | **Fail:** 20 rescans grow one error's marks from 4 to 84; replacing an error line with plain text leaves a stale error entry. These are additional reduced cases, not verbatim upstream reproducers. |
| Related to ANSI / [#119](https://github.com/ej-shafran/compile-mode.nvim/issues/119) | `ansi_recompile_extmarks` | **Fail:** an identical 100-line colored recompilation grows total extmarks from 202 to 404. |

The new nearest-previous-error request
[#163](https://github.com/ej-shafran/compile-mode.nvim/issues/163) is a feature
proposal, not treated as an existing-contract failure. Completion-plugin UI,
Windows-specific shell behavior, Telescope/lualine integration, and real compiler
or terminal rendering differences still require their own environments. Existing
command/configuration/interrupt tests provide the baseline coverage for those
core behaviors that do not need such integrations.

## Measurement method

Environment: macOS 15.7.3 arm64, Neovim 0.12.5, LuaJIT 2.1.1788856981;
Plenary `74b06c6c75e4eeb3108ec01852001636d85a932b`,
Baleia v1.3.0 `fb3aff021b2b64ef820d0230d2c22ebfaf71bb6a`.
Raw results: [54-scenario run](measurements/benchmark-macos-arm64.json) and
[plain-output recheck](measurements/benchmark-plain-recheck.json).

Each scenario has one discarded warmup and seven recorded samples. Preparation,
fixture construction, explicit garbage collection, correctness checks, and buffer
cleanup are outside the timer. GC remains enabled during the measured operation.
Fresh rendering/scanning fixtures are rebuilt for each sample. Metadata cases
start with a saved compilation working directory, as actual commands do.

The end-to-end scenarios intentionally reuse the compilation buffer: the warmup
uses `Compile`, followed by seven `Recompile` samples. They include child-Neovim
startup and scheduling. They are a **repeated-command workload**, not independent
cold starts. Their auxiliary arrays include the warmup and retain chronological
order so growing costs are visible. Module wrappers collect synchronous stage
costs; scheduled Baleia work and redraw/reentrant work are not cleanly separable
from every enclosing timer. Stage times are descriptive, not an exact additive
CPU accounting model.

The ordinary fixtures have one short output line per item; `mixed` means 10%
GNU-style errors and 90% plain text. The normalization microbenchmark includes
two hidden-output patterns, while end-to-end compilation uses none. ANSI stage
measurements include scheduled work draining; plain stage measurements measure
the synchronous API calls. Incremental tests use a prefilled buffer to isolate
scan/render granularity from producer and write costs.

`p95` with seven samples is the largest observation, not a reliable population
tail estimate. The JSON also records retained Lua KiB after GC, which can be noisy
and excludes native buffer/extmark memory. The 5 ms heartbeat measures event-loop
callback gaps, not rendered frame latency. These are local headless measurements,
not guarantees for other machines or an interactive UI.

One of the 54 scenarios (`end_to_end/plain/10000`) timed out waiting for
`CompilationFinished`; the other 53 completed. An isolated recheck completed all
samples. Both raw records are retained. Treat this as an unresolved lifecycle
observation, not a confirmed deterministic plugin defect or a successful full run.

## Stage results

Median milliseconds unless specified otherwise. The counts in the first column
matter: do not compare 100 navigations with one buffer write as if they were the
same operation.

| Workload | 1,000 lines/errors | 10,000 lines/errors | Implication |
| --- | ---: | ---: | --- |
| Normalize plain output, two hidden patterns | 2.34 | 24.42 | Much smaller than recognition/scanning for this corpus |
| Recognize plain nonmatching lines | 25.69 | 264.65 | Ordinary logs still try the matcher table |
| Recognize error lines | 32.14 | 323.42 | Capture extraction adds cost beyond rejecting nonmatches |
| Scan plain buffer range | 31.18 | 324.11 | Error matching plus directory/prefix checks dominate |
| Scan error buffer range | 30.98 | 327.92 | Similar scale to standalone recognition |
| Render fresh error highlights | 2.47 | 28.25 | Less costly than scanning in isolation |
| Visit already-highlighted errors **100 times** | 0.40 | 6.32 | Skipping individual highlights still traverses the error table |
| Incremental scan/render, one line per call | 94.80 | 1,531.33 | Repeated full-table visits/redraws grow with chunk count |
| Incremental scan/render, 100 lines per call | 35.00 | 535.16 | About **2.86×** faster at 10,000 lines for this isolated workload |
| ANSI filter + write/drain | 0.67 | 6.21 | Low cost for this sequence mix |
| ANSI Baleia render + write/drain | 10.30 | 188.49 | Significant color-rendering cost; investigate marks separately |
| Plain buffer write/drain | 0.13 | 0.74 | Raw insertion is not the main bottleneck here |
| Status counts **100 times** | 1.81 | 19.75 | Full recounts are measurable at redraw frequency |
| Next-error navigation **100 times** | 11.25 | 156.18 | Sorting/traversing error keys per action is a secondary target |
| Quickfix conversion once | 0.92 | 11.71 | Measure again with many directory transitions after correctness repair |
| Diagnostic conversion once | 8.03 | 83.42 | Per-entry filename resolution and `bufadd` deserve caching/indexing |
| Trim metadata once | 0.009 | 0.287 | Lower priority for these sizes |

1,000 directory lookups with 1 / 100 / 1,000 transitions took **0.005 / 0.628 /
4.652 ms**. Configuration validation 100 times took about **16 ms**; neither is the
first target for the observed ordinary-log stall.

For 100 nonmatching lines, increasing each line from 32 to 512 to 4,096 bytes
increases recognition time from **3.41 to 43.84 to 318.51 ms**. The per-matcher
profile exercises all 42 built-ins: on 4,096-byte nonmatches the largest individual
costs were GNU (~59 ms), Maven (~35 ms), and 4BSD (~27 ms), with substantial cost
spread across other matchers too. This supports investigating both matcher
selection and individual patterns rather than assuming one regex explains all
latency.

## End-to-end behavior

The isolated plain-output recheck processed 10,000 lines in **351.54 ms median**
(**356.96 ms sample p95**). Its median synchronous scan time was **316.43 ms**;
normalization and ANSI filtering/writing each used roughly 4–6 ms. Heartbeat gaps
reached **93.47 ms**. This directly connects ordinary-output responsiveness to
parsing work, even with few/no errors or color extmarks.

The repeated 10,000-error workload had a median of **599.85 ms** and retained
40,000 error extmarks per run. The repeated 10,000-line ANSI workload had a median
of **824.24 ms**, but a single median conceals the growth:

| Recompile sample | Wall time (ms) | Total extmarks after run |
| --- | ---: | ---: |
| 1 | 442.10 | 40,010 |
| 2 | 602.81 | 60,015 |
| 3 | 724.12 | 80,020 |
| 4 | 934.76 | 100,025 |
| 5 | 824.24 | 120,030 |
| 6 | 1,060.83 | 140,034 |
| 7 | 1,733.75 | 160,038 |

The warmup already left 20,005 marks. The strongest ANSI heartbeat gap reached
**800.06 ms**. This is evidence of retained highlights and degrading repeated-run
behavior. It does not establish that every extra millisecond is caused by those
marks; a cleanup implementation still needs controlled before/after measurements.

## Prioritized optimization work

1. **Repair highlight/metadata lifecycle first.** Make rescanning a range replace
   its old error records and marks; clear owned ANSI marks on a fresh compilation
   and prevent compilation-only window matches leaking into source windows.
   Preserve unrelated namespaces. Gate changes on `reparse_extmarks`,
   `reparse_stale_error`, `ansi_recompile_extmarks`, and `highlight_scope`, and
   require stable mark counts over repeated commands. This addresses both stale
   functionality and accumulating rendering work.
2. **Bound parsing work per event-loop turn.** Coalesce small callbacks, scan only
   dirty ranges, highlight only new/changed errors, and coalesce redraws. The
   chunk-size experiment supports batching, but unlimited batches would worsen
   latency: retain a time/line budget and yield. Require lower heartbeat gaps,
   preserved output/order within each stream, and correct completion/interrupt
   behavior. Fix `scroll_filter`/`scroll_render` while defining update boundaries.
3. **Reduce matcher work without narrowing supported formats.** Profile the costly
   patterns, consider cheap proven preconditions or a candidate index, and avoid
   unnecessary regex recompilation/capture reconstruction. Preserve custom
   priority, ignored filenames, severity and mixed-language logs. PR #62's
   first-successful-matcher shortcut is not generally safe for the mixed-language
   guard; parsing only successful commands would also lose useful failure output.
4. **Repair directory coordinates, then index repeated queries.** Quickfix and
   diagnostics must resolve using `error.linenum`, while source positions remain
   `error.row`. Once the two directory probes pass, evaluate ordered transitions
   with binary search or sequential lookup, and per-file diagnostic grouping.
   Keep nested entering/leaving-directory correctness tests.
5. **Cache navigation order and severity counts behind explicit invalidation.**
   Reuse sorted line keys/counts across reads; update them on parsing, replacement,
   trimming and session reset. These are secondary improvements after scan/render
   and lifecycle work. Avoid hiding stale-cache bugs under faster reads.

The completion-event timeout needs a focused lifecycle investigation before
introducing queues. Track pending parse/render work, job ownership and finish
ordering. No optimization should be accepted solely because `make bench` becomes
faster while the corresponding issue expectations still fail.
