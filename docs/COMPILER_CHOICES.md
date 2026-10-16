# Open-source Pascal compiler research

**Research maintainer:** Amirali Yazdani  
**Research snapshot:** 14 October 2026

Research snapshot checked on 14 October 2026. This is a shortlist, not a claim that no other project exists.

## Candidates found

### Free Pascal Compiler (FPC)

- Project: <https://github.com/fpc/FPCSource>
- Official site/FAQ: <https://www.freepascal.org/> · <https://www.freepascal.org/_new/docs/faq/general/>
- Mature compiler for Pascal/Object Pascal dialects, with source and broad platform support.
- Its compiler is written in Pascal and is self-hosting; it is not a C++/Objective-C/Swift compiler library that can be dropped into this Swift package.
- The compiler source is GPL v2; the runtime library uses a modified LGPL with an exception. A distribution/integration plan needs a deliberate license review.
- It does not natively supply MPWin-specific `FORALL`, `FORK`/`JOIN`, processor placement, ports, channels, and the visual teaching-simulator semantics this app is built to expose. Using FPC would require a separate standard-Pascal mode or a translator/runtime layer for those constructs.

### `rmerkel/P` — simple Pascal-like compiler/interpreter

- Project: <https://github.com/rmerkel/P>
- A small C++-based compiler/interpreter inspired by PL/0. Its README states that the original goal of ISO-compatible Pascal was abandoned and the language diverged. It is useful as a learning reference, not as a production-ready Multi-Pascal replacement.

### `kpfromer/pascal-interpreter` — C++ interpreter

- Project: <https://github.com/kpfromer/pascal-interpreter>
- A small C++ Pascal interpreter with CMake build files. It is a useful language-learning reference, but the repository is a small standalone interpreter rather than a demonstrated full MPWin implementation. There is no visible support for the MPWin process constructs and simulator state that this app needs.

### `rochus-keller/FreePascal` — grammar/parser and code browser

- Project: <https://github.com/rochus-keller/FreePascal>
- C++ parser/code-browser work for Free Pascal syntax, described by its README as work in progress. It is not a complete replacement execution engine for this application's custom process model.

### `Kreijstal/Pascal-Compiler` (KGPC) — C compiler project

- Project: <https://github.com/Kreijstal/Pascal-Compiler>
- The repository describes KGPC as an alpha C compiler that parses/checks/optimizes Pascal and emits x86-64 assembly, using GCC or Clang for assembly/linking.
- Its stated purpose is bootstrapping Free Pascal, and its language coverage and API remain in development. It does not implement MPWin parallel processes or the simulator's topology, ports, channels, and visual scheduling model.
- License: AGPL v3. That is an additional integration constraint, so it is not a drop-in candidate for this app.

### `Pascual` — self-hosted Pascal compiler

- Project: <https://github.com/jtarrio/pascual>
- An open-source self-hosting compiler, written in Pascal rather than C++, Objective-C or Swift. It may be useful for studying compiler architecture, but it is not an MPWin compiler.

## What the search did—and did not—find

The repositories above are useful examples of Pascal front ends, interpreters or a mature compiler, but the reviewed candidates do not provide a drop-in compiler/runtime for the MPWin dialect with its custom process semantics. In this search I did not find a mature Objective-C- or Swift-written Pascal compiler that implements these constructs. That is a search result, not proof that no such repository exists anywhere. A generic Pascal compiler being written in C++ would still not make it compatible with this specific dialect.

## Recommendation for this app

Keep the current Swift lexer/parser/semantic loader and simulator as the main implementation. The custom process semantics and visual state are the educational purpose; swapping in a general Pascal compiler would not add those features automatically. Consider an optional FPC-backed standard-Pascal mode only if the product explicitly needs to compile ordinary Pascal beyond MPWin's language subset. Do not translate the current core to C++ merely to change implementation languages: that creates a Swift/C++ interop boundary and a second debugging surface without solving the dialect-compatibility problem by itself.

Swift can call C and Objective-C APIs, and modern Swift supports C++ interoperability, but interoperability is not an argument for a rewrite on its own. Before adopting any external parser/compiler, confirm language coverage, runtime semantics, license obligations, platform support, maintenance activity, and the work required to represent MPWin process creation and communication.
