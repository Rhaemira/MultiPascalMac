# MPWin (Multi-Pascal for Windows 2.0) — Recovered Specification

**Research notes maintained by:** Amirali Yazdani

Clean-room reimplementation notes. Everything here was recovered from:

- The author's official manual `MPWinHelp.chm` (June 2008), extracted with `chmlib`.
- Static string/resource analysis of `MPWinP.exe` (Delphi/VCL, PE32, 1,189,888 bytes,
  SHA-256 `7b7f6fe03ea32031238681df85797b7b944bb85b658bfaff594188531067d9b5`).
- The author's exercise booklets (`f02`–`f09`), which contain real Multi-Pascal programs.

Upstream: <http://users.sch.gr/areti/mpwin.html> (Areti N. Kaptan, University of Macedonia).

> Note: `MPWinHelp.chi` is **not** the manual. It is the 18 KB help *index*; the manual is
> `MPWinHelp.chm` (573 KB) shipped in `MPWinHelp.zip`.

## 1. Program structure

```
Program <name>;
Architecture <Topology>(<n>);      { optional, must precede Const }
Const ...
Type ...
Var ...                             { shared variables: main program level }
  <nested procedure/function decls> { allowed inside the main declaration part }
Begin
  <statement> ...
End.
```

`Architecture` must appear immediately after the `Program` header, before `Const`
(MPWin: `Architecture.html`). Default architecture is `Shared(512)`.

### Statement blocks with local declarations

Any statement group may be preceded by a `Var` section, producing a local scope:

```
Forall i := 1 to n do
  Var j, k : Integer;
  begin
     ...
  end;
```

(MPWin: `StatementBlocks.html`)

## 2. Types

### Standard

`Integer`, `Real`, `Boolean`, `Char`.

Type constructors: `array[..] of T`, `record ... end`, `^T` (pointer), `Type` sections,
`Const` sections.

### Built-in concurrency types

| Type        | Meaning                                                        |
|-------------|----------------------------------------------------------------|
| `Channel`   | FIFO queue used for process synchronisation / message passing   |
| `Spinlock`  | Test-and-set mutual exclusion flag                              |

`Channel` component type may be any valid type, including `array`, `record` and pointer.
When the component type is `array`/`record`/`pointer`, indexing into the channel variable
is illegal — only whole-value read/write is allowed (MPWin: `Channel.html`).

### Explicitly unsupported

Enumerated types, subrange types, sets, packed arrays, variant records, files, strings
(MPWin: `UnsupportedFeatures.html`).

## 3. Operators

- Arithmetic: `+ - * / div mod`
- Comparison: `< > = <> <= >=`
- Logical: `and or not xor shl shr`
- Address: `^`
- Channel-empty test: `chan?` (yields Boolean; `TRUE` when the channel holds a value)
- Processor allocation: `(@expr)` prefix on a process-creating statement
- `Writeln`/`Write` field width: `write(V:X)` and `write(V:X:Y)` for real/integer fields
  (both `X` and `Y` must be integer expressions)

## 4. Process-creating statements

### `Forall`

```
Forall <indexVar> := <initial> To <final> [Grouping <size>] Do <statement>
```

Creates one child process per index value, executed in parallel. `Grouping size` packs
`size` consecutive index values into each child process; the last child gets the remainder.
Requires `1 < size <= final - initial + 1`.

Optional prefix on the body:

```
Forall i := 1 to n do (@expr) <statement>
Forall i := 1 to n do (@expr Port ch1; ch2) <statement>
```

### `Fork` / `Join`

```
Fork <statement>;
Join;
```

`Fork` creates one child that runs independently; the parent continues immediately. When a
parent's own body finishes it implicitly waits for all of its children. `Join` suspends the
parent until one child terminates; there must be one `Join` per child, otherwise the parent
blocks forever (deadlock). Extra `Join`s cause permanent blocking.

`For i := 1 to 10 do Fork A[i] := i;` creates 10 children. `Fork For i := 1 to 10 do A[i] := i;`
creates exactly 1 child.

### `Port`

```
(Port <channelList>) <statement>
(Port chan) Compute;
(Port archan) Compute;          { whole array of channels }
(Port A[3, 4]) Normalize;
(Port A[1, 1]; A[2, 1]) VectorProduct;
```

Assigns channel variables to the created process so it can *receive* on them. Any number of
senders may write to a channel; only one receiver may be assigned to it. In multicomputer
topologies a channel becomes a physical communication link between the sending processor and
the processor owning the receiving port.

`@` and `Port` combine: `Fork(@i*n+j Port A[i,j]; B[i,j]) Multiply(...)`.

## 5. Built-in procedures / functions

| Item        | Kind     | Semantics                                                            |
|-------------|----------|----------------------------------------------------------------------|
| `Duration`  | procedure| Suspends the process for exactly the given number of time units.    |
| `%Seqoff`   | procedure| Excludes subsequent instructions of this process from sequential time.|
| `%Seqon`    | procedure| Re-enables sequential-time accounting.                                |
| `Lock`      | procedure| `Repeat X := TestAndSet(L) Until X = 0` — busy-wait; process spins.  |
| `Unlock`    | procedure| Writes 0 into the spinlock cell.                                     |
| `%Self`     | function | Processor number the current process runs on.                        |
| `%Myid`     | function | Current process number.                                               |
| `Seqtime`   | function | Estimated sequential (uniprocessor) elapsed time up to this point.   |
| `Clock`     | function | Estimated parallel elapsed time up to this point.                    |

A `Spinlock` is an ordinary memory cell: `0` = unlocked, `1` = locked. `TestAndSet` is
atomic. Spinlocks are a multiprocessor feature; using one in a multicomputer architecture is
a runtime error (`USE OF SPINLOCK IN MULTICOMPUTER`).

## 6. Architectures

| Topology      | `n` means      | Total processors |
|---------------|----------------|------------------|
| `Shared(n)`   | processors      | `n`              |
| `Line(n)`     | processors      | `n`              |
| `Ring(n)`     | processors      | `n`              |
| `Mesh2(n)`    | side length     | `n²`             |
| `Torus(n)`    | side length     | `n²`             |
| `Mesh3(n)`    | side length     | `n³`             |
| `Hypercube(n)`| dimension       | `2ⁿ`             |
| `Bus(n)`      | processors      | `n`              |
| `Star(n)`     | side length     | `n²`             |
| `Fullconnect(n)` | processors   | `n`              |

Maximum 512 processors, numbered `0..n-1`.

In `Shared`, all variables live in one central memory and any process may touch it in one
time unit. In multicomputer topologies each processor owns its memory, and the shared
database is partitioned across local memories; remote data is reached by message passing
(data partitioning).

## 7. Process model

- Process 0 is the main program and always runs on processor 0.
- New processes are assigned to the first free processor starting at processor 1; when all are
  busy, the process goes to the processor with the smallest accumulated workload.
- The `@` operand overrides allocation.
- Process count may exceed processor count; each processor time-slices its processes.
- Process names come from the program/procedure/function that created them.

### States

`READY`, `RUNNING`, `BLOCKED`, `DELAYED`, `SPINNING`, `TERMINATED`.

- **Blocked** — waiting on an event from another process (empty channel read, parent waiting
  for children, `Join` with no child left).
- **Delayed** — the awaited event has occurred but has not yet arrived over a link with
  communication delay.
- **Spinning** — busy-waiting on a locked spinlock.

### Default timing parameters

| Parameter                   | Default    | Source                                  |
|-----------------------------|------------|-----------------------------------------|
| Process creation time       | 5          | `ProcessCreationTime.html`              |
| Context-switch limit        | 50         | `ProcessContextSwitchLimit.html`        |
| Context-switch time         | 5          | `ProcessContextSwitchTime.html`         |
| Channel read/write time     | 3          | `ChannelReadWriteTime.html`             |
| Communication link delay    | 10         | `Delay.html`                            |
| Packet size                 | 3 values   | `PacketSize.html`                       |
| Time alarm                  | user-set   | `Alarm.html`                            |
| Profile sampling step       | ≥ 10 (20)  | `ProgramPerformanceProfileParameters.html` |
| Process-activity sample step| 10         | `ProcessActivityChart.html`             |
| Variation random seed       | user-set   | `Variation.html`                        |
| Congestion                  | off        | `Congestion.html`                       |

Processor speed varies by factor `1/e_i` when Variation is enabled; the same seed must always
produce the same factors.

### Communication delay accrues at

1. writing to a communication channel,
2. creating a new process,
3. writing to a `var` parameter that resides in a remote address space,
4. process termination.

(Derived from the author's exercise sheets, Units 8 and 9.)

### Congestion

Optional extra delay when many packets contend for links between distant processors. Only
applies to multicomputer architectures and is recomputed on each `Run`.

## 8. Metrics

```
Performance Statistics for Program
  Sequential Execution Time: <t>
  Parallel Execution Time: <t>
  Speedup: <s>
  Number of Processors Used: <n>
```

`Seqtime` accumulates the estimated sequential time, excluding regions between `%Seqoff` and
`%Seqon`. Speedup = sequential / parallel.

## 9. GUI contract

Menus: **File, Edit, Run, Parameters, Debug, View, Charts, Help**.

- File: New, Open, Save, Save As, Load Input File, Save Log File As, Load Charts,
  Save Charts, Print, Exit. Source filter `MPWin 2.0 Files (*.mpf)`, input filter
  `Input Files (*.in)`, log/chart filter `Text Files (*.txt)`.
- Run: Compile, Run, Program Reset. Shortcuts: compile `Ctrl+F9` (macOS: `⌘F9`), run `F9`.
- Debug: Add/Clear Breakpoint, Display, Trace Variable, Clear Trace, Write Variable, Step
  (`F7`), Step Process (`F8`), Continue.
- Parameters: Variation, Time Alarm, Communication Link Delay, Congestion, Packet Size,
  Program Performance Profile Parameters, Memory Access Pattern Parameters,
  Process Creation Time, Process Context-Switch Limit, Process Context-Switch Time,
  Channel Read/Write Time.
- View: Parallel Execution Time, Processor Utilization, Processor Channel Watches,
  Process Status, Process Memory Stack, Memory Access Pattern, Performance Metrics,
  Textual Info.
- Charts (post-mortem only): Process Activity Chart, Process Tree, Process Assignment Chart,
  Program Performance Profile, Processor Overall Utilization, Channel Communication Chart,
  Channel Activity Chart, Workpool Chart, Multicomputer Topology, Close All Charts.

Process status table columns: `PROCESS #  PROCEDURE  LINE NUMBER  STATUS  PROCESSOR`.

Source is locked between `Compile` and `Program Reset`. Compilation numbers every source line.
Breakpoints may only be set on executable lines.

## 10. Diagnostics (verbatim from the binary)

Compile-time:

- `A semicolon ";" was expected but not found.`
- `The keyword "COEND" was expected but not found.`
- `The first word in each type definition must be an identifier or one of the following: ARRAY, RECORD, ^, CHANNEL.`
- `The identifier must be a "Type Identifier".`
- `In a FOR or a FORALL statement, the index variable must be of type INTEGER, CHAR or BOOLEAN.`
- `The expression must evaluate to the same type as the index variable of the FOR or FORALL statement.`
- `Constants must be defined by a literal or a previously defined constant identifier.`
- `The bounds of the index in the array definition exhibits one of the following errors: lower exveeds upper bound, types of bounds do not much, type is real, index range exceedsthe limit 32767.`
- `Two values must be of the same type to be compared, with the exception of comparing integers with reals.`
- `In a statement of the form WRITE(V:X:Y) or WRITE(V:X) both expressions X and Y must be INTEGER.`
- `A statement must begin with a variable or procedure identifier, except for assigning the result of a function.`
- `Error in the indicated expression.`
- `The paremeter in a procedure or function call does not match the type in the procedure or function definition. Also, channels can only be VAR parameters.`
- `One of the following illegal use of channelq: nested channel definition, indexing a channel, applying a field selector to a channel.`
- `It is not permitted to modify the value of a FORALL index varialbe. A FORALL index may not appear on the left side of an assignment, in a READ statement, or as a VAR parameter.`
- `NEW and DISPOSE can be used only with pointer variables.`
- `A built-in multicomputer topology was expected but not found`
- `Multicomputer architecture parameters must be positive integer values`
- `The expression following the keyword "GROUPING" must evaluate to an integer.`
- `Somewhere in the type declarations, a pointer is defined to a type that is undefined.`

Run-time:

`DIVISION BY 0`, `INVALID INDEX`, `EXPRESSION EVALUATION OVERFLOW`, `TOO MUCH OUTPUT`,
`LINE TOO LONG`, `READING PAST END OF FILE`, `TOO MANY CHANNELS OPEN`,
`CHANNEL BUFFER OVERFLOW`, `TOO MANY PROCESSES`, `INVALID PROCESSOR NUMBER`,
`ILLEGAL MEMORY REFERENCE`, `UNDEFINED CASE`, `INVALID CHARACTER`, `STORAGE OVERFLOW`,
`ILLEGAL GROUP SIZE`, `REFERENCE TO A NONLOCAL VARIABLE`, `USE OF SPINLOCK IN MULTICOMPUTER`,
`CHANNEL IS EMPTY`, `Pointer is NIL`, `NIL POINTER`, `Too many levels of structure`,
`Data Has Too Many Levels of Structure`, `UNLOCKED`, `LOCKED`.

Deadlock is reported as:

```
    DEADLOCK:  All Processes are Blocked
For Further Information Type STATUS Command
```

## 11. Reserved words (exact table from the binary)

```
AND ARRAY BEGIN CASE CHANNEL CONST DIV DO DOWNTO ELSE END FOR FORALL FORK
FUNCTION GROUPING IF JOIN MOD NOT OF OR PORT PROCEDURE PROGRAM RECORD
REPEAT SHL SHR THEN TO TYPE UNTIL VAR WHILE WITH XOR
FALSE TRUE NIL CHAR BOOLEAN INTEGER REAL SPINLOCK
ABS SQR ODD CHR ORD SUCC PRED ROUND TRUNC SIN COS EXP LN SQRT ARCTAN
EOF EOLN %SELF CLOCK SEQTIME %MYID
READ READLN WRITE WRITELN NEW DISPOSE LOCK UNLOCK DURATION %SEQOFF %SEQON
```

Internal interpreter event names found in the binary, useful as a sanity check on the
execution model: `store`, `atchan`, `ticket`, `ready`, `block`, `delay`, `wrchan`,
`newproc`, `endproc`, `parameval`, `storeinttoreal`, `myne`.

## 12. Open items / calibration

The exact per-statement time cost is not stated in the manual. The original charges time per
executed statement plus per-loop-iteration overhead; the author's exercises set time alarms
at values (e.g. 1700 and 4600 time units) that do not match a naive 1-unit-per-statement
model. `TimingModel` in `MPWinCore` therefore keeps every cost in one place with the
documented defaults above, pending calibration against the Windows binary.
