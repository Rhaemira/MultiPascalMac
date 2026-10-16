# Contributing

**Maintainer:** Amirali Yazdani

Contributions that improve correctness, documentation, accessibility, or reproducibility are welcome.

## Before opening a change

1. Search the existing issues and documentation to avoid duplicating work.
2. Keep changes focused and explain the language behavior or user-facing problem they address.
3. Add regression tests for parser, compiler, evaluator, scheduler, or runtime changes.
4. Update the compatibility notes when language support or simulator behavior changes.
5. Do not describe simulated timing as real CPU performance or claim full historical MPWin compatibility without evidence.

## Checks

Run the following commands from the repository root:

```sh
swift test
swift build -c release
swift run mpwin Samples/HelloParallel.mpf
swift run mpwin Samples/ParallelMatrixMultiplication.mpf
swift run mpwin Samples/RankSortParallel.mpf --input Samples/RankSortParallel.in
```

Changes to the native interface should also be tested on macOS in Xcode. Include a concise description of the manual checks performed.

## Code and documentation style

- Prefer small, named functions and clear diagnostics.
- Preserve existing MPWin semantics unless a deliberate compatibility correction is documented and tested.
- Keep documentation factual and specific; avoid claims that cannot be reproduced.
- Do not commit credentials, signing identities, local build products, or personal files.
