# Development Guide

**Maintainer:** Amirali Yazdani

## Repository layout

```text
Sources/
├── MPWinCore/             Parser, syntax tree, loader, evaluator, machine, values, timing
├── MultiPascalMac/        SwiftUI/AppKit macOS application
└── mpwin/                 Command-line runner
Tests/MPWinCoreTests/      Core regression suite
Samples/                   MPWin source programs and input fixtures
docs/                      Compatibility, language research, and distribution notes
.github/workflows/         Continuous integration
```

## Local workflow

From the repository root:

```sh
swift test
swift build -c release
swift run mpwin Samples/HelloParallel.mpf
swift run mpwin Samples/ParallelMatrixMultiplication.mpf
swift run mpwin Samples/RankSortParallel.mpf --input Samples/RankSortParallel.in
```

When changing parser or runtime behavior, add a focused regression test in `Tests/MPWinCoreTests/MPWinCoreTests.swift`. Prefer tests that verify observable output or diagnostics rather than relying on private implementation details.

## Core execution pipeline

1. `Parser.swift` tokenizes and parses source into the syntax representation.
2. `Syntax.swift` and `AST.swift` define diagnostics and syntax-tree structures.
3. `Loader.swift` performs name/type resolution and lowers the parsed program into the internal instruction representation.
4. `Evaluator.swift` resolves expressions and runtime values.
5. `Machine.swift` simulates processes, virtual processors, scheduling, communication, and execution state.
6. `Timing.swift` contains configurable operation costs used by the simulator.
7. `MultiPascalMac/` presents the core state through the native macOS interface; `mpwin/` exposes a command-line runner for tests and examples.

## Error handling and limits

Runtime arithmetic and resource boundaries should produce diagnostics, not unchecked host-language traps or unbounded allocations. The current safety ceilings are documented in `COMPATIBILITY.md`. Changes to these limits should include regression tests and an explanation of the trade-offs.

## Native UI verification

The editor and interface use AppKit and SwiftUI. The Linux test job can verify the cross-platform compiler core and CLI, but it cannot validate the active macOS UI. Before release, build and run on macOS and test editing, line-number scrolling, file operations, execution controls, breakpoints, and light/dark appearance.
