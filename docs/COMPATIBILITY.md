# Compatibility and validation notes

**Maintainer:** Amirali Yazdani

## What this application is

The application parses the MPWin/Multi-Pascal teaching-language source into an AST, resolves names and types, lowers statements to its internal instruction representation, and executes those instructions in `Machine`. It is a compiler front-end plus bytecode-like interpreter and simulator; it does not currently emit native executable code.

## Implemented and tested areas

| Area | Scope represented in this implementation |
|---|---|
| Declarations | Program header, constants, named types, globals, procedures/functions, local declarations and recursion; required declaration semicolons are diagnosed |
| Primitive types | Integer, real, boolean, char; plus pointer, channel, spinlock, arrays and records |
| Expressions | Arithmetic, comparisons, boolean/bitwise operators, precedence, built-ins and mixed integer/real arithmetic |
| Statements | Assignment, blocks, `IF`, `CASE`, `WHILE`, `REPEAT`, `FOR`, `FORALL`, `FORK`, `JOIN`, read/write and memory operations |
| Parallel-language model | `FORALL` creation and synchronization, grouping, processor placement, ports, channels, spinlocks and processor/topology accounting |
| Syntax validation | Statement sequences require semicolon separators; declaration entries require their semicolons; `END.` requires the final period. Valid trailing semicolons and intentional empty statements are preserved. |
| Debugging/inspection | Step/continue/stop, breakpoints, source-line diagnostics, process state, bounded processor-local operation/context-switch trace, and estimated timing metrics |
| Safety | Invalid topology sizes, arithmetic overflow, non-finite real literals, oversized type/global declarations, pathological `FORALL` fan-out and excess process creation become diagnostics rather than unchecked host arithmetic or unbounded allocation |

This table describes the intended implemented scope and the parts represented in tests; it is not a claim of formal conformance or exhaustive validation of all source combinations.

## Known language and fidelity limits

- The recovered MPWin language specification explicitly lists enumerated types, subrange types, sets, packed arrays, variant records, files, and string variables as unsupported. String literals and output are supported by this implementation.
- Exact timing costs were recovered from documentation where available, but not every timing detail has been recalibrated against the original MPWin Windows program. Virtual speedup is pedagogical model output.
- The Activity tab's operation timeline is built from actual simulator events and uses each processor's accumulated simulated cost units. It includes scheduler context-switch overhead and source-line/instruction events, but it is not a shared wall-clock trace or a measurement of host CPU utilization. The trace is capped at 50,000 events to bound memory usage.
- Processor concurrency is modeled by a deterministic single-threaded event loop and per-processor workload accounting. The application does not execute the simulated processes simultaneously on OS threads.
- Simulated storage declarations are capped at **1,000,000 words per program**, and the runtime caps active/created simulated processes at **10,000**. `FORALL` range and grouping arithmetic is checked before spawning children. These are implementation safety limits to prevent host-memory exhaustion and integer overflow, not assertions about historical MPWin limits.
- Parser coverage and tests are substantial but finite. Unusual syntax combinations, edge cases in historic dialect behavior, and differences from undocumented original behavior may remain.
- The core test suite can be run on Linux with SwiftPM; the native SwiftUI/AppKit interface must be built and exercised on macOS. A successful Linux core test run does not establish that the AppKit branch has passed a full macOS type-check, GUI test or manual scrolling test.

## Reproducible checks

From this package directory:

```sh
swift test
swift run mpwin Samples/HelloParallel.mpf
swift run mpwin Samples/ParallelMatrixMultiplication.mpf
swift run mpwin Samples/RankSortParallel.mpf --input Samples/RankSortParallel.in
```

Expected sample checks:

- `HelloParallel.mpf` includes output `1 64`.
- `ParallelMatrixMultiplication.mpf` includes `C[1,1] = 196`, `C[8,8] = -308`, and `Checksum = 2688`.
- RankSort prints `1 2 3 3 5 7 8 9` for the included eight-integer input.

The timing numbers may change when implementation or timing parameters change; correctness should be verified against program output separately from performance metrics.
