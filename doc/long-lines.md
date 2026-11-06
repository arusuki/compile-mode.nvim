# Fragmented long-line output

An unfinished line used to concatenate, normalize, render and rewrite its entire
prefix on every callback. For fixed-size fragments, the total processed bytes
were proportional to `1 + 2 + ... + n`. The 128-entry/64 KiB queue batch limits
could not bound the retained prefix from earlier batches.

The runner owns a separate `output.new_stream` collector for stdout and stderr.
Ordinary unfinished tails
up to 64 KiB retain their immediate updates and the existing batch-normalization
path. Larger tails retain fragments without concatenation. A snapshot is
published when retained bytes double, when a newline arrives, or at process exit.
Deferred batches skip the complete normalization/ANSI/write/parse pipeline. This
bounds cumulative prefix replay by a fixed short-line budget plus O(N), where N
is the total input size. It does not make arbitrary custom regexes linear or
bound one enormous final buffer write.

The collector retains its last published raw tail plus unpublished fragments.
Publishing calls `output.normalize` with that exact tail/delta boundary and
passes its replay metadata to the stream-local ANSI context. Replayed OSC
handlers retain their previous results; new controls execute once, including
controls in text overwritten by a CR. This also preserves partial SGR/OSC
sequences spanning the last published prefix and deferred fragments.

Without hidden-output patterns, the collector detects an effective CR overwrite
and publishes pending raw bytes once, then lets the normalizer compact the tail.
Discarded control sequences reach ANSI processing before their text is removed.
Short progress updates remain live after a long line; CR-only fragments do not
repeatedly force full snapshots. With hidden patterns, original CR history remains available for
cross-fragment substitutions; scheduling uses raw retained bytes before filtering,
even when the visible line is empty. NUL removal and partial ANSI handling remain
compatible with the previous final output.

The tradeoff is deliberately limited to intermediate long-line display: it can
lag until the next length boundary, newline, or exit. Full final output remains
available, and EOF flushing runs through parsing and scheduled ANSI work before
`CompilationFinished`. EOF snapshots for both streams pass through the timer-based
consumer and parsing stages, revisiting each stream's published row when necessary.
Interruption discards deferred text with queued output,
preventing a stale suffix from appearing in a subsequent compilation. There is
no new configuration option. `max_lines` still counts output lines, and
`max_parse_line_length` independently limits parsing, not display or retention.

## Historical measurements before audit integration

This table records the original `29d9b52` implementation against `f7d20fa`, before
rebasing onto the audit fixes in `4091981`. It is historical evidence, not a
measurement of the integrated runtime's wall time. The environment was macOS
arm64 / Neovim 0.12.5 / LuaJIT.
Each case has one warmup and five measured samples in a fresh Neovim process.
The fixture is 1000, 2000 or 4000 fragments of 256 ASCII bytes, with no newline.
The normalization case exercises the collector or the legacy normalizer. The
pipeline case uses deterministic `jobstart` callbacks, drains scheduled work
between callbacks to prevent queue coalescing, and includes the real buffer,
ANSI and parser calls, EOF, footer, and completion event. It excludes child
process startup. Every sample asserts exact final text. The optimized cases
also assert a bound on cumulative bytes sent to the next stage.

Timing samples are retained as observations, not CI performance thresholds;
other local work can affect wall time. Exact replay bytes and content assertions
are the primary scaling evidence. The first 256 callbacks still refresh the
short tail immediately, so the optimized totals include a fixed 8,421,376-byte
prefix budget before geometric snapshots.

| Stage / fragments | Before median (ms) | After median (ms) |
| --- | ---: | ---: |
| normalization / 1,000 | 37.35 | 7.76 |
| normalization / 2,000 | 152.83 | 13.20 |
| normalization / 4,000 | 497.10 | 24.65 |
| pipeline / 1,000 | 4235.61 | 687.10 |
| pipeline / 2,000 | 15778.87 | 733.65 |
| pipeline / 4,000 | omitted | 798.03 |

| Fragments | Before replay bytes | After replay bytes | Before / after writes |
| --- | ---: | ---: | ---: |
| 1,000 | 128,128,000 | 8,808,448 | 1,000 / 258 |
| 2,000 | 512,256,000 | 9,326,592 | 2,000 / 259 |
| 4,000 | 2,048,512,000 | 10,362,880 | 4,000 / 260 |

The normalization and measured pipeline cases have identical replay counts.
The 4000-fragment reference pipeline timing was omitted after the 2000-fragment
case took 15.78 seconds per sample; its byte count above is measured at the
normalization boundary. No pipeline wall-time extrapolation is reported.
All samples, runtime hashes and dependency revisions are recorded in
[the measurement JSON](measurements/long-lines.json).

## Integrated validation and reproduction

The complete Plenary suite passes 285 tests after integration with `4091981`,
including 18 long-line cases. Coverage
includes short/live output, empty lines, NULs, CR overwrite and pending CR,
hidden patterns spanning deferred CR history, randomized mixed chunking, final
unterminated output, exit before/after consumer draining, final error parsing
and highlights at the completion event, split ANSI rendering, max_lines, and
interruption followed by recompilation. Additional integration cases check two
interleaved long streams pending at EOF, geometric OSC replay, partial SGR and
new OSC events in CR-discarded text, replay metadata offsets when an earlier
stream row is revisited, hidden patterns across CR history, and CR-only/NUL
fragments. Work-count tests check both the collector
and actual ANSI/buffer entry point rather than relying on timing thresholds.
StyLua and LuaLS checks pass. A separate 1000-case randomized differential probe
also matches the legacy final text across CR/NUL/ANSI fragments, UTF-8, large
chunks and hidden-output regexes.

The [integrated scaling record](measurements/long-lines-integrated.json) repeats
the structural byte-count and final-text assertions on the audit-integrated
runtime, using timer-separated callbacks. No slow historical baseline rerun was
needed. The fixed short-line budget plus linear prefix bound remains the
acceptance criterion; its timings should not be compared directly with the
historical scheduled-drain harness above.

```sh
export PLENARY_PATH=/path/to/plenary.nvim
export BALEIA_PATH=/path/to/baleia.nvim
make bench-long-lines CHECK_ARGS='--samples 5 --output .measurements/long-lines.json'
```

To measure the reference, copy `scripts/long_lines.lua` and the updated
`scripts/run_checks.py` into a separate checkout of `f7d20fa`. The benchmark uses
the legacy API when `output.new_stream` is absent, with identical inputs and
final-content assertions. Use the scripts from `29d9b52` for the exact historical
scheduled-drain harness; the current harness additionally crosses timer turns.
Ordinary checks remain `make test`, `make fmt-check`,
and `make typecheck`. In a sandbox without writable editor state, the tests were
run using a temporary init that adds the installed Baleia runtime path and sets
`swapfile=false` and `shadafile=NONE`; production configuration is unchanged.

The compatibility `output.normalize(data, tail, hidden)` function still returns
a full snapshot as before. External callers requesting every growing prefix from
that function still pay for those requested snapshots; the runner and the new
stream API avoid requesting them. Retained text and queued output still have no
byte cap, and a custom regex or a final huge line can still take substantial
synchronous time. These are separate limits from repeated-prefix amplification.
