# Runtime and UI state-machine inventory

This document records the state machines that are currently implemented across the editor, app model, compiler front end, and simulator. Several are implicit: state is distributed across optionals, booleans, counters, queue membership, and per-frame continuation data rather than represented by one enum.

## 0. Editor and compiler front end

### Native editor coordination

**State holders:** the SwiftUI source binding, `NSTextView.string`, selected ranges, the `NSScrollView` clip-view bounds, and the line-number ruler.

The editor has two directions of synchronization:

- **User edit:** AppKit changes the text view; `textDidChange` writes the new text into the SwiftUI binding; the app model marks the document modified; syntax coloring and line numbers refresh.
- **External source replacement:** SwiftUI updates the representable; `updateNSView` replaces the text view contents, restores the selection within the new string bounds, then refreshes syntax coloring and the ruler.
- **Scroll:** the scroll view's clip-view bounds notification invalidates the ruler so line numbers are redrawn against the text view's current visible coordinates.

The ruler is not an independent scroll view. It derives glyph positions from the same TextKit layout manager as the editor.

### Lexer and parser

**Lexer state:** UTF-8 byte index, line, and column. Each token request moves through trivia, nested brace comments, parenthesized comments, line comments, identifiers/directives, numeric literals, quoted strings, operators, and EOF. Unterminated comments/strings and invalid characters transition to a diagnostic rather than returning a partial token.

**Parser state:** token array plus current token position. The recursive-descent parser moves through the program header, optional architecture, declaration sections, routine declarations, type constructors, statement lists, and expressions. Statement-list parsing has explicit termination conditions for compound blocks, repeat loops, and CASE arms; missing separators or terminators produce syntax diagnostics. A successful parse returns an AST for the Loader; the parser itself does not own long-lived runtime state.

## 1. Document lifecycle

**State holders:** `source`, `fileURL`, `documentName`, `isDirty`, `compiledProgram`, `compiledSource`, `diagnostics`.

| State | Entry | Important exit |
|---|---|---|
| Untitled / clean | New app or New Document | Editing, opening a file, or opening a sample |
| Saved / clean | Open or successful save | Any source edit |
| Modified / dirty | `source` changes | Successful save, discard, or source replacement |
| Compiled snapshot current | Compile succeeds | Any source edit, new/open/sample, or explicit recompile |
| Compile failed | Parser/loader throws | Next successful compile or source replacement |

Two independent facts are tracked: `isDirty` means the in-memory text differs from the saved document, while `compiledSource == source` means the compiled program corresponds to the current text. Compiling does not mark the file as saved. The app recompiles only when no compiled program exists or the source snapshot no longer matches.

## 2. App operation lifecycle

**State holders:** `isRunning`, `machine`, `lastOutcome`, `cancellationToken`, `operationID`.

The app has these practical states:

- **Idle:** no simulation is executing.
- **Waiting for input:** the program requires input and no input source is configured.
- **Running:** a fresh machine is executing in a detached task.
- **Stepping:** one requested simulator step is executing in a detached task.
- **Paused at breakpoint:** the machine remains alive and can be continued or stepped.
- **Stopped:** cancellation was requested and observed.
- **Completed:** all simulated processes terminated.
- **Failed:** a runtime error, deadlock, time alarm, or emergency safety limit occurred.

`operationID` is an epoch token. A result is applied only if its task still owns the latest epoch; document replacement or reset invalidates stale completions. `SimulationCancellation` is a separate cooperative stop signal.

A single `ActiveSheet?` now represents Parameters, Input, or About. This replaces three independent presentation booleans that could express overlapping sheet states.

## 3. Simulator and process scheduler

**State holders:** `runQueue`, `Process.state`, `BlockReason`, `readyAt`, processor assignments, and the simulator's two time measures.

Process states:

`READY → RUNNING → READY` for a normal time-sliced process; `RUNNING → BLOCKED → READY` for a process that suspends; and `RUNNING → TERMINATED` when its body and children finish.

A process is runnable only when its ID is in the run queue. A blocked process may be awakened by a channel send, spinlock release, duration expiry, child termination, or FORALL completion. The public process state is intentionally smaller than the internal suspension state.

The scheduler supports Round-Robin and seeded Random selection. The previous Shortest-Job-First option was removed because it used the same FIFO dequeue operation as Round-Robin and did not implement shortest-job selection.

### Suspension sub-state

`BlockReason` distinguishes channel reads, spinlocks, duration waits, JOIN, FORALL, and implicit child completion. The following fields refine that state:

- `waitingOn` identifies the channel buffer being read.
- `readyAt` and `pendingWakeAt` represent timed suspension.
- `heldLock` tracks a spinlock owned by the process.
- `waitingForForallChildren` and `children` track structured child lifetimes.
- `forallContinuation` stores the next grouped iteration.
- The instruction pointer remains on a suspended statement; pending duration and recorded function/channel results preserve progress across a retry.
- `sequential` changes time-slice behavior after SEQOFF.
- `skipBreakpointOnce` allows one statement to resume after a breakpoint.

These fields form a cross-product state machine. Invariants are enforced by scheduler helpers rather than a single transition function; this remains a maintenance risk.

## 4. FORALL / FORK child lifecycle

A FORALL parent creates children, stores their IDs, and blocks until all of that FORALL's children terminate. A grouped child carries a continuation with its next and final index and loops through its inline body. A FORK parent continues immediately; the parent itself cannot terminate until its children finish. JOIN waits for one child termination per JOIN.

The parent/child relationship is distinct from the global run queue: a child can be ready or blocked while its parent is blocked on a FORALL or waiting for children.

## 5. Expression evaluation and statement replay

**State holders:** each `Frame.callResults`, `callCursor`, and `callResultIndex`, plus `Process.waitingOn` and the unchanged instruction pointer.

An expression can call a function or read a channel. Either operation can suspend while the containing statement is being evaluated. Retrying the entire statement would repeat side effects or consume another channel value, so the caller frame records completed call results and a cursor. The retried statement replays recorded results before evaluating new work.

This is an interpreter-level continuation mechanism. It is essential to the correctness of expressions that contain multiple blocking channel reads or functions with side effects.

## 6. Channel lifecycle

Each channel is a reference-backed FIFO buffer. Sending appends a value and wakes the eligible blocked reader; reading removes one value or blocks if the FIFO is empty. A read result is also recorded in the current frame so a statement retry does not consume a second value.

`PORT` assigns one spawned process as the sole receiver of each listed channel. Any process may send. A receiver cannot be reassigned while another receiver owns the channel, and ownership is released when the receiver terminates. Arrays of channels expand into their individual channel buffers when passed to `PORT`.

Local arrays containing channels must create a distinct buffer for every element. Regression tests cover independent buffers, indexed channel reads, scalar receiver assignment, array receiver assignment, and conflicting receivers.

Current limitation: the queue is unbounded. The former `capacity` field was not enforced and has been removed rather than suggesting that back-pressure existed. Congestion, packet capacity, physical link routing, and processor-to-processor distance are not modeled; multicomputer channel operations pay a fixed link-delay cost.

## 7. READ / READLN input cursor

**State holders:** `inputLines`, `inputLine`, and `inputColumn`.

The cursor moves through an immutable line array. Numeric READ skips spaces and line boundaries; character READ can consume an end-of-line as a blank; READLN consumes the rest of the current line. EOF and EOLN are derived from the same cursor.

The UI separately tracks the current input text and its source label. These are input-source state, not compiler state.

## 8. Debugger breakpoints

**State holders:** the app's breakpoint set, the machine's matching set, `stoppedAtLine`, and per-process `skipBreakpointOnce`.

The app accepts only executable source lines from the compiled source map. When a process reaches a breakpoint, it remains runnable at that instruction and marks that process to skip the same breakpoint once on resume. Continue and Step clear the machine-level stop marker but preserve the process-level one-shot skip.

## 9. Timing and observation

There are two deliberately different clocks:

- `time` is the deterministic event-loop clock used by duration wakeups and the time alarm. It accumulates costs as the single-threaded scheduler processes events.
- `metrics.parallelTime` is the maximum accumulated simulated workload on any virtual processor, with completed `DURATION` intervals contributing an elapsed-time floor. It does not sum independent processors' work.

CLOCK reads the parallel elapsed value. A process records both its event-loop wake deadline and the corresponding parallel-time deadline when it begins `DURATION`; the latter is committed when the scheduler wakes it. Processor activity records executed instruction and context-switch events; profile sampling is controlled by `profileSampleStep`. The former activity-sampling setting was miswired to profile collection and has been removed.

## 10. Remaining state and semantic gaps

- PORT binds one process as each channel's receiver; bindings are released when that process terminates. Sender access remains unrestricted. Port ownership and channel wakeups are enforced by the runtime.
- Channel queues do not model packet capacity, congestion, physical link routing, or distance-dependent delivery delay; multicomputer channel operations use a fixed link-delay cost.
- The simulator is a deterministic single-threaded event loop; virtual processors are modeled, not native threads.
- The macOS editor, sheets, file panels, and menu commands have not been validated by GUI automation in this source audit. The UI is a native SwiftUI/AppKit app, not a web page to be opened in Chrome.
