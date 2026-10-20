# Changelog

**Maintainer:** Amirali Yazdani

Notable project changes are recorded here. This file begins with the 1.1 development line; it is not a claim that a signed public release has already been published.

## 1.1 — Development

- Added a native source editor with a shared scroll view and line-number ruler.
- Improved syntax diagnostics, statement/declaration separator validation, and final program-period checks.
- Added safeguards for arithmetic overflow, pathological memory declarations, pointer indexes, and excessive process creation.
- Expanded support and regression tests for ordinal values, `FORALL` grouping, channels, processor placement, and simulated activity traces.
- Added processor activity history with instruction and context-switch events.
- Added a custom application icon and a DMG packaging workflow.
- Clarified the distinction between simulated parallel elapsed time and native CPU performance.
- Fixed `READ`/`READLN` input handling across lines, `EOF` after the last line, and CRLF input.
- Fixed uninitialized procedure locals, `VAR` parameters bound to a caller's local variable, and `NEW` on a non-nil pointer.
- Parameterless functions can now be called without parentheses.
- Stop now interrupts endless loops inside functions and works after Continue from a breakpoint.
- Step runs off the main thread, so a step into a non-returning function no longer freezes the app.
- A function that blocks (for example on a channel read) is no longer called a second time when its statement resumes, and `WRITE` no longer repeats output when an item blocks.
