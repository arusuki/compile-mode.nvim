# Profile-guided optimization

Measured on 2026-11-07, macOS arm64 / Neovim 0.12.5 / LuaJIT 2.1.1788856981.
The reference is commit `a4aff49`; the optimized result is the working tree.
This follows the historical [baseline report](performance.md). No user command,
configuration option, or event payload was removed.

## Upstream evidence and actual profiles

The author's open [#119](https://github.com/ej-shafran/compile-mode.nvim/issues/119)
collects performance work and links to
[#56](https://github.com/ej-shafran/compile-mode.nvim/issues/56) (large output and
`rg -H a .` freezing the editor) and
[PR #62](https://github.com/ej-shafran/compile-mode.nvim/pull/62). The author declined
the latter's broad changes. We retained realtime parsing, failed-command errors,
mixed-language matching, custom priorities, and filename exclusion semantics.
These sources and comments were re-read for this implementation.

The current baseline was executed locally, followed by LuaJIT line-level stack
sampling (`jit.profile`, requested 1 ms interval), then three subagents implemented
matcher, incremental-parser, and ANSI-lifecycle fixes. Integration work covered
queue scheduling, ownership, completion ordering, live scrolling, and regression
validation; the agents also cross-reviewed matcher and queue correctness.

The saved stack profiles cover three repetitions each of plain logs, incremental
errors, repeated ANSI commands, and a real ripgrep corpus. They identify:

- Plain scanning: 58.9% of baseline samples at the error regex `match_str` call,
  19.9% at repeatedly compiling the command-prefix regex. See
  [before](measurements/stacks-plain-before.json) and
  [after](measurements/stacks-plain-after.json).
- Incremental errors: 37.6% in regex matching, 20.3% in capture extraction, and
  10.4% in Plenary coroutine creation/dispatch. The repeated whole-error-table
  traversal was additionally isolated by the chunk-size benchmarks. See
  [before](measurements/stacks-incremental-before.json) and
  [after](measurements/stacks-incremental-after.json).
- ANSI: regex work and Baleia native highlight APIs are prominent; repeated runs
  also accumulate extmarks. After optimization, Baleia's highlight creation is
  the largest individual sampled stack (39.7%). See
  [before](measurements/stacks-ansi-before.json) and
  [after](measurements/stacks-ansi-after.json).
- Actual ripgrep output: matching plus capture extraction dominate. After the
  change, capture extraction alone remains 53.6% of samples. See
  [before](measurements/stacks-log-before.json) and
  [after](measurements/stacks-log-after.json).

The sampler attributes native work to the calling Lua stack; it does not resolve
C-internal functions. Its callbacks add overhead, so sampled wall times are not
used as speedup numbers. OS sampling precision varies, and the optimized plain
scan has only 28 samples: its percentage breakdown is too small to rank precisely.

## Implemented changes

1. **Candidate filtering without changing matcher order.** Each builtin regex is
   indexed by its exact regex text to a proven necessary literal. Literal presence
   is cached once per input line. Unknown/custom regex text runs normally; a
   custom replacement cannot inherit an incompatible gate. All 42 builtins have
   positive witness tests. The command-prefix regex is compiled once.
2. **Work proportional to the changed range.** Scan results carry selected errors;
   rendering visits those records instead of every accumulated error. Rescans
   replace stale errors, directory records, and owned marks. Deleted derived marks
   are not restored by undo. Deferred results cannot restore newer replacements.
   Status redraws are coalesced, and the synchronous parser no longer creates a
   coroutine for every invocation.
3. **One output consumer with bounded batches.** Callback data queues in order;
   adjacent tails are merged with linear fragment concatenation, and queue removal
   advances an index. Batches stop at 128 entries or approximately 64 KiB, plus an
   empty tail when required by a split newline. The consumer yields around parsing
   and scheduled ANSI rendering. Exit waits for pending work; interruption revokes
   ownership before yielding. Completed jobs remove their deletion handlers.
4. **Owned highlight lifecycle.** ANSI uses a private Baleia namespace, clears
   replaced ranges including scheduled old writes, and resets on buffer reuse.
   Replaying a raw partial line no longer prepends its escape fragment twice.
   Compilation window matches are installed once, removed when the window leaves
   the buffer, and restored on return. Foreign namespaces and matches are retained.
5. **Diagnostic export and live output fixes.** Quickfix/diagnostics resolve paths
   using output `linenum`, while destination positions use source `row`. Diagnostic
   conversion caches `bufadd` by resolved path within that call. Rowless messages
   remain in quickfix but are not assigned invented diagnostic positions. The new
   output consumer applies autoscroll to windows displaying the compilation buffer.

## Controlled before/after measurements

The [comparison JSON](measurements/optimization-comparison.json) contains the
runtime source hashes, original revision, dependency revisions, all samples, stage
timings, and corpus SHA-256. Each case ran in its own clean headless Neovim, with
one discarded warmup and five measured repetitions. A final serial before/after
run avoided overlapping benchmarks or sampling. Preparation and explicit GC are
outside microbenchmark timers. The process workload includes child startup.

Times below are medians in milliseconds, with identical fixture definitions.

| Workload | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| Recognize 10,000 plain lines | 263.43 | 13.51 | 19.50× |
| Recognize 10,000 lines, 10% errors | 269.18 | 36.15 | 7.45× |
| Recognize 10,000 error lines | 319.71 | 240.97 | 1.33× |
| Scan 10,000 plain lines | 318.11 | 34.96 | 9.10× |
| Recognize 100 nonmatches of 4,096 bytes | 315.21 | 0.40 | 782.98× |
| Scan/render 10,000 errors one line at a time | 1300.16 | 359.58 | 3.62× |
| Convert 10,000 diagnostics | 68.59 | 10.42 | 6.58× |
| Compile 10,000 plain lines | 366.22 | 77.97 | 4.70× |
| Compile 10,000 error lines | 425.99 | 351.29 | 1.21× |
| Compile 10,000 ANSI lines, reused buffer | 581.68 | 217.92 | 2.67× |
| Replay 2,900 actual ripgrep output lines | 152.34 | 131.43 | 1.16× |

Five samples do not support a robust tail percentile. Instead, the following
shows the largest observed 5 ms heartbeat gap across the five measured runs,
excluding warmup. This measures event-loop availability, not visible frame delay.

| End-to-end workload | Before gap (ms) | After gap (ms) |
| --- | ---: | ---: |
| plain | 96.87 | 15.51 |
| errors | 291.92 | 17.22 |
| ansi | 378.13 | 17.89 |
| log | 94.89 | 13.00 |

The repeated ANSI workload's mark counts were `[20005, 40010, 60015, 80020,
100025, 120030]` before (warmup included). Afterward they remain at 19,923 across all six executions: 10,000 green text
spans and 9,923 invisible end-of-line reset spans. The removed 77 resets are
batch-boundary empty spans, not missing text colors. A regression test checks
every visible line and color span across two 10,000-line executions. The error
workload retains 40,000 marks each time, as expected.

The ripgrep fixture is 2,900 actual output lines from searching the reference
repository, replayed through a subprocess. The earlier independent run measured
171.83→173.28 ms ([before](measurements/rg-before.json),
[after](measurements/rg-after.json)), whereas the final control above measured a
modest throughput gain. Responsiveness improved in both runs; large throughput
claims for this workload would not be justified. The very large long-nonmatch
speedup is specific to the punctuation-free synthetic fixture, not a universal
regex speedup.

The full stage matrices also completed: [baseline](measurements/profile-baseline.json)
and [optimized](measurements/profile-optimized.json), 54 scenarios each. Older
result files call the normalization counter `output_callbacks`; after queuing this
counts processed batches, not raw OS callbacks. The final comparison uses the
unambiguous field `normalization_batches`.

## Reproduction

From the repository root, set `PLENARY_PATH` and `BALEIA_PATH` to the installed
checkouts (Baleia v1.3.0 was used), then:

```sh
make issues
make bench CHECK_ARGS='--samples 5 --output .measurements/benchmark.json'
COMPILE_MODE_RESULT=.measurements/stacks.json \
  nvim --headless --clean -u scripts/minimal_init.lua \
  -l scripts/profile.lua plain 10000 3
# Other sampling workloads: errors, incremental, long, ansi, log.
```

To reconstruct the exact real-output fixture, create a separate checkout of
`a4aff49` and run this in that checkout:

```sh
rg --line-number --no-heading --color never a lua spec > /tmp/compile-mode-rg.txt
```

Then, from the implementation under measurement:

```sh
BENCH_LOG=/tmp/compile-mode-rg.txt make bench \
  CHECK_ARGS='--samples 5 --cases end_to_end/log/2900'
PROFILE_LOG=/tmp/compile-mode-rg.txt COMPILE_MODE_RESULT=.measurements/rg-stacks.json \
  nvim --headless --clean -u scripts/minimal_init.lua \
  -l scripts/profile.lua log 2900 3
```

Use the current `scripts/benchmark.lua` and `scripts/profile.lua` in the reference
checkout as well; these only instrument the runtime. `BENCH_LOG` expects a text
file ending in a newline. Run measurements serially. Normal tests and formatting
remain `make test`, `make fmt-check`, and `make typecheck` with development tools.

## Correctness and remaining costs

The Plenary suite passes **189 tests, 0 failures**. Stylua and LuaLS checks pass.
The [validation record](measurements/optimization-validation.json) records the
commands and runtime fingerprint.

The [before issue run](measurements/issues-before-optimization.json) had 8 passes
and 8 failures. The [optimized run](measurements/issues-optimized.json) passes all
16 probes, including rescanned errors, repeated ANSI commands, directory exports,
window highlight scope, and scrolling during a live subprocess. New regression
coverage also tests all builtin candidates, custom overrides, mixed languages,
exit-before-drain, synchronous jobs, cancellation followed by recompilation,
fragmented ANSI output, multiple windows, and preservation of foreign marks.

The strongest remaining costs are capture extraction on matching lines and
Baleia highlight creation. Navigation still sorts error keys; status counts and
directory transitions still use linear scans. Those were measured but not given
persistent caches with extra invalidation requirements in this change.

Batching cannot interrupt one native regex call: a single exceptionally long
line can exceed the soft byte budget. With no configured `max_lines`, output
retention remains unbounded. Stdout and stderr still share the historical partial
line model. These headless results do not establish interactive GUI frame latency
or performance on other hardware or Neovim versions.
