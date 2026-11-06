# Hotspot acceptance results

Measured on macOS arm64 with Neovim 0.12.5 and Baleia 1.3.0. The baseline is
`573ed4d`; the integrated runtime is `d3fcbd8`. Each workload uses one warmup and
five measured samples in a fresh Neovim process. Tables report medians in ms;
the linked JSON files retain individual samples, p95, source fingerprints and
dependency revisions. The pipeline baseline was rerun separately after parallel
agent work finished to avoid concurrent test load.

## Results

| Workload | Before | After |
| --- | ---: | ---: |
| 1,000 / 2,000 / 4,000 CR callbacks, 256 bytes each | 79.0 / 332.7 / 1,382.8 | 4.93 / 9.59 / 19.74 |
| 1,000 / 2,000 / 4,000 hyperlinks on one line | 33.4 / 129.2 / 508.4 | 2.72 / 5.55 / 11.08 |
| One 1 MiB line ending in `:`: scan only | 141.45 | 0.055 |
| 10,000 errors and 10,000 directory transitions: Quickfix | 1,064.5 | 12.97 |
| Same metadata: generic diagnostic conversion | 1,080.5 | 12.08 |
| Same metadata: three same-file diagnostic queries, including cold build | 3,225.2 | 14.31 |
| Parse 10,000 GNU errors | 236.59 | 106.38 |
| Scan 10,000 GNU errors | 249.57 | 119.18 |
| Render 10,000 whole-line ANSI colors, including scheduled work | 175.95 | 17.28 |
| Filter the same ANSI lines | 6.28 | 6.44 |
| 100 navigation operations over 10,000 errors, including initial index build | 155.60 | 2.38 |
| 100 status queries over 10,000 errors, including initial index build | 19.93 | 2.36 |
| End-to-end 10,000 ANSI lines | 213.70 | 83.64 |
| End-to-end 10,000 error lines | 488.55 | 249.43 |
| End-to-end 10,000 plain lines | 77.62 | 73.00 |

The 1 MiB result measures the new explicit skip policy, not equivalent full
parsing. Without directory transitions, Quickfix remains approximately 9.4–9.6 ms
and diagnostics 8.3–8.7 ms. Cached diagnostic queries use the same entry point as
source jumps; they exclude `vim.diagnostic.set` and editor drawing. End-to-end
results include producer startup and scheduled processing and vary with callback
grouping; they do not establish a visible editor frame-time bound.

Raw results: [focused baseline](measurements/hotspots-before.json),
[focused optimized](measurements/hotspots-after.json),
[pipeline baseline](measurements/hotspot-pipeline-before.json),
[pipeline optimized](measurements/hotspot-pipeline-after.json), and
[issue checks](measurements/hotspot-issues.json).

## Implementation and limits

- Without hidden-output patterns, normalization retains the final visible CR
  segment plus one pending CR. Displayed content and incomplete ANSI bytes remain
  replayable. Arbitrary hidden Vim regexes can span old CR segments, so that path
  retains its original raw history and cost. A growing line without CR also still
  requires writing its growing text; `max_lines` cannot bound its byte length.
- `max_parse_line_length` defaults to 65,536 bytes. Longer lines remain in the
  buffer but skip error, directory and command-prefix recognition. Set it to `0`
  to restore unlimited parsing. Parser rendering requests a status redraw only
  when severity counts or effective run/exit state change. An actual redraw
  remains synchronous; the option does not bound buffer writes or ANSI work.
- Directory lookup searches ordered transition indexes. Batched range removal
  and deferred error sorting avoid repeated array shifts during full or prefix
  reparses. Navigation and status queries reuse ordering and severity counts.
  Session diagnostic groups invalidate with errors, directory transitions and
  the compilation directory. Generic `todiagnostic` remains an uncached export.
- Internal metadata writes use setters and range-clear helpers. Replacing legacy
  tables is detected automatically; external in-place changes to tables or error
  records require `errors.invalidate()` or `dir.invalidate()`. This contract is
  documented in [architecture.md](architecture.md).
- OSC scanning accumulates byte columns and finds BEL/ST terminators in one
  forward pass. Small CSI state also accounts for SGR text split across custom
  handler output and following text.
- Common GNU captures use an exact-regex-gated ASCII shortcut and retain native
  `match_str` validation. Ambiguous positions, custom patterns, case-insensitive
  matching and unsupported forms retain general capture extraction. ASCII command
  prefixes have a separate equivalent shortcut; Unicode uses Vim's regex rules.
- Closed, independent whole-line ANSI colors reuse Baleia-generated style plans
  and emit only nonempty highlight ranges: the 10,000-line fixture drops from
  20,000 marks to 10,000. This is not just a highlight-definition cache. Plans are
  bounded, optional private helpers are checked, and incompatible layouts,
  options or helper results fall back to Baleia's public writer. Arbitrary
  multi-span/cross-line ANSI rendering is not accelerated by this shortcut.

## Validation and reproduction

The baseline full suite passed **189/189**. The integrated full suite passed
**217/217**. After replacing the deprecated highlight API with equivalent
extmarks, the four ANSI parity/fallback tests and seven ANSI lifecycle tests
passed again. StyLua and LuaLS at Warning level pass. All 16 standalone issue
probes pass. Regression coverage includes long-line policy and opt-out, deferred
status updates, matcher capture parity, cache invalidation, reset/trim, directory
boundaries, partial CR/ANSI output, custom OSC handlers, and rendering fallbacks.

Additional deterministic acceptance checks compared 80,000 normalization
callbacks with the baseline, 40,000 GNU candidates with native extraction, and
25,000 metadata mutations with a simple reference model; no mismatches were found.
These supplement the permanent regression cases in `spec/`.

With development dependencies available, run:

```sh
export PLENARY_PATH=/path/to/plenary.nvim
export BALEIA_PATH=/path/to/baleia.nvim
python3 scripts/run_checks.py hotspots --samples 5
python3 scripts/run_checks.py benchmark --samples 5 --sizes 1000,10000
python3 scripts/run_checks.py issues
make test
make fmt-check
make typecheck
```

`hotspots` includes content, link-count and export-count assertions and imposes
no machine-dependent timing thresholds. For the same-file diagnostic repeat
case, the runner selects the cached jump API when available and the legacy export
otherwise, always including the first conversion in the measured operation.
