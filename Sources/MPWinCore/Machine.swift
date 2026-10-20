// Created by Amirali Yazdani on 10/16/26.
import Foundation

// MARK: - Process model

public enum ProcessState: String, Sendable, CaseIterable {
    /// Runnable, waiting for its turn on a processor.
    case ready
    case running
    /// Its time slice expired before it finished.
    case preempted
    /// Waiting on a channel read, a `Lock`, a `Duration`, a `Join` or a child process.
    case blocked
    case terminated

    /// The status text the original shows in its process table.
    public var statusText: String {
        switch self {
        case .ready: return "Ready"
        case .running: return "Running"
        case .preempted: return "Preempted"
        case .blocked: return "Blocked"
        case .terminated: return "Terminated"
        }
    }
}

public enum BlockReason: Sendable, Equatable {
    case channelRead(MemoryRef)
    case spinlock(MemoryRef)
    case duration
    case join(remaining: Int)
    /// A FORALL parent is blocked until all children created by that FORALL terminate.
    case forall(remaining: Int)
    /// The body finished but the process must not terminate until its children do.
    case waitingForChildren(remaining: Int)

    public var description: String {
        switch self {
        case .channelRead: return "Waiting for input on a channel"
        case .spinlock: return "Waiting for a spinlock"
        case .duration: return "Suspended by DURATION"
        case .join(let remaining): return "Waiting for \(remaining) child process(es)"
        case .forall(let remaining): return "Waiting for \(remaining) FORALL child process(es)"
        case .waitingForChildren(let remaining): return "Waiting for \(remaining) child process(es)"
        }
    }
}

public struct ProcessStatus: Sendable, Identifiable {
    public let id: Int
    public let routineName: String
    public let lineNumber: Int
    public let state: ProcessState
    public let processor: Int
    public let blockReason: BlockReason?
    public let readyAt: Int?

    public init(id: Int, routineName: String, lineNumber: Int, state: ProcessState,
                processor: Int, blockReason: BlockReason?, readyAt: Int?) {
        self.id = id
        self.routineName = routineName
        self.lineNumber = lineNumber
        self.state = state
        self.processor = processor
        self.blockReason = blockReason
        self.readyAt = readyAt
    }
}

public final class SimulationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum RunOutcome: Sendable, Equatable {
    case completed
    case breakpoint(line: Int)
    case timeLimitExceeded
    case deadlock
    case stepLimitReached
    case cancelled
    case runtimeError(String)

    public var isFailure: Bool {
        if case .runtimeError = self { return true }
        if case .deadlock = self { return true }
        if case .timeLimitExceeded = self { return true }
        return false
    }
}

/// Thrown when the current statement cannot make progress in the current time slice.
enum Suspend: Error {
    case block(BlockReason, readyAt: Int?)
}

/// Thrown from inside a function call evaluated inline, so a runaway function can
/// still be stopped.
enum Interrupt: Error {
    case cancelled
    case timeLimitExceeded
}

// MARK: - Frames and processes

/// One activation record. Locals live in a flat slot array; `var` parameters are held
/// as references into the caller's storage.
struct Frame {
    var routine: Int
    var op: Int
    var scope: Scope
    var slots: [Value?]
    var varParams: [MemoryRef]
    /// `slots.count` when each open `Var ... begin` block was entered.
    var blockMarkers: [Int]
    /// Scopes active for declaration blocks/loop scopes.
    var scopeMarkers: [Scope]
    /// Saved caller state, so the machine can return without a dedicated return opcode.
    var returnAddress: ReturnAddress?
    var executed: Int = 0
    /// Results of the functions called by the statement this frame is executing. When the
    /// statement blocks and is retried, finished calls return their recorded result instead
    /// of running (and repeating their side effects) again.
    var callResults: [CallResult] = []
    var callCursor = 0
    /// Where the caller records this frame's result, when it was called from an expression.
    var callResultIndex: Int?

    struct ReturnAddress {
        var routine: Int
        var op: Int
    }

    struct CallResult {
        /// `nil` while the call is still in progress.
        var value: Value?
        /// The cursor position after this call, so a replay skips the calls made while
        /// evaluating its arguments.
        var next: Int
    }

    init(routine: Int, op: Int, scope: Scope, slots: [Value?], varParams: [MemoryRef] = [],
         blockMarkers: [Int] = [], scopeMarkers: [Scope] = []) {
        self.routine = routine
        self.op = op
        self.scope = scope
        self.slots = slots
        self.varParams = varParams
        self.blockMarkers = blockMarkers
        self.scopeMarkers = scopeMarkers
    }
}

struct ForallContinuation {
    var nextIndex: Int
    let lastIndex: Int
    let indexSlot: Int
    let bodyStart: Int
}

final class Process {
    let id: Int
    var state: ProcessState = .ready
    var processor = 0
    var frames: [Frame]
    /// True when the next step should retry the statement that suspended.
    var resumePending = false
    /// The `Duration` wake time carried across a suspend/resume cycle.
    var pendingWakeAt: Int?
    /// The spinlock this process currently holds, if any.
    var heldLock: MemoryRef?
    /// The channel this process is trying to read, while blocked.
    var waitingOn: ChannelBuffer?
    var blockReason: BlockReason?
    var readyAt: Int?
    /// Steps remaining in the current time slice.
    var slice: Int
    /// Set by `Seqoff`: the process runs until its body ends.
    var sequential = false
    /// Children spawned by this process, in creation order.
    var children: [Int] = []
    var executedStatements = 0
    var createdAt = 0
    var sequentialTime = 0
    var ports: [MemoryRef] = []
    var forallContinuation: ForallContinuation?
    /// Child process IDs belonging to the currently executing FORALL, when its parent is blocked.
    var waitingForForallChildren: [Int]?
    var skipBreakpointOnce = false

    init(id: Int, frame: Frame, processor: Int, slice: Int) {
        self.id = id
        self.frames = [frame]
        self.processor = processor
        self.slice = slice
    }

    var frame: Frame {
        get { frames[frames.count - 1] }
        set { frames[frames.count - 1] = newValue }
    }

    var terminated: Bool { state == .terminated }
}

// MARK: - Machine

/// The parallel simulator. Execution uses a deterministic single-threaded event loop,
/// while per-processor work accounting is used to derive parallel elapsed time.
public final class Machine: @unchecked Sendable {
    /// Keeps adversarial FORALL/FORK programs from exhausting host memory.
    /// This is a simulator safety ceiling, not a language-level processor limit.
    private static let maximumProcessCount = 10_000
    /// Bounds dynamic pointer-cell expansion; this is a host-safety limit, not a Pascal rule.
    static let maximumPointerCells = 1_000_000
    public let program: CompiledProgram
    public let options: ProgramOptions
    public private(set) var time = 0
    var processes: [Process] = []
    public private(set) var output = ""
    public private(set) var metrics = Metrics()
    /// Executed statements per processor. This is a count, not utilization percent.
    public private(set) var processorLoad: [Int]
    /// Bounded, exact event history for the MPWin-inspired processor timeline.
    public private(set) var processorActivity: [ProcessorActivityEvent] = []
    public private(set) var activityTraceTruncated = false
    private static let maximumActivityEvents = 50_000
    private var nextActivityEventID = 0
    /// Accumulated simulated work/cost on each processor. Used to derive parallel
    /// elapsed time for compute-bound workloads: processors execute concurrently,
    /// so wall time is governed by the busiest processor rather than the sum of
    /// all processors' work.
    public private(set) var processorBusyTime: [Int]
    private var activeProcessor: Int?
    /// Source lines at which execution stopped for the debugger.
    public private(set) var stoppedAtLine: Int?
    public var breakpoints: Set<Int> = []
    /// Collects the profile the original's `PROFILE` command produces.
    public var collectProfile = false
    public private(set) var profileSamples: [ProfileSample] = []
    private static let maximumProfileSamples = 200_000

    var sharedMemory: [Value?]
    private var runQueue: [Int] = []
    private var nextProcessID = 0
    private var random: SplitMix64
    private var inputLines: [[Character]]
    private var inputLine = 0
    private var inputColumn = 0
    private var stepCounter = 0
    let timing: TimingModel
    private let processorCount: Int
    private let cancellation: SimulationCancellation?
    var isCancelled: Bool { cancellation?.isCancelled == true }

    public init(program: CompiledProgram, options: ProgramOptions = ProgramOptions(),
                cancellation: SimulationCancellation? = nil) {
        self.program = program
        self.options = options
        self.timing = options.timing
        self.sharedMemory = [Value?](repeating: nil, count: max(1, program.globalFootprint))
        self.processorCount = max(1, program.architecture.topology.processorCount(
                                        parameter: program.architecture.parameter))
        self.cancellation = cancellation
        self.processorLoad = [Int](repeating: 0, count: processorCount)
        self.processorBusyTime = [Int](repeating: 0, count: processorCount)
        self.activeProcessor = nil
        self.random = SplitMix64(seed: options.seed)
        var lines = (options.input ?? "")
            // "\r\n" is a single Character in Swift, so it must be matched explicitly.
            .split(omittingEmptySubsequences: false,
                   whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { Array($0) }
        // A final line terminator ends the last line; it does not start another one.
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        self.inputLines = lines
    }

    // MARK: Lifecycle

    public func start() {
        let main = program.routines[program.mainRoutine]
        var frame = Frame(routine: program.mainRoutine, op: 0, scope: main.scope,
                          slots: [Value?](repeating: nil, count: max(1, main.localCount)))
        initializeFrame(&frame, using: main.scope)
        let process = Process(id: nextProcessID, frame: frame, processor: 0,
                              slice: timing.contextSwitchLimit)
        nextProcessID += 1
        processes.append(process)
        for (_, binding) in program.globalScope.table {
            if case .global(let ref, let type) = binding {
                storeGlobal(ref, type: type, value: type.defaultValue)
            }
        }
        runQueue.append(process.id)
    }

    // MARK: Running

    public func run() -> RunOutcome {
        var steps = 0
        var runIterations = 0
        while true {
            runIterations += 1
            // Emergency guard only. Legitimate parallel programs can require many
            // scheduling iterations; the old 500-iteration debug guard stopped
            // perfectly valid workloads and could even crash while inspecting a
            // terminated process whose frame had already been removed.
            if runIterations > 1_000_000 {
                return .stepLimitReached
            }
            if isCancelled {
                metrics.processCount = processes.count
                metrics.parallelTime = time
                return .cancelled
            }
            // A breakpoint leaves the process positioned on the statement.
            // The next Run/Continue call should resume past that same breakpoint.
            stoppedAtLine = nil
            if let limit = options.timeLimit, time >= limit {
                return .timeLimitExceeded
            }
            guard let pid = dequeueRunnable() else {
                return finish()
            }
            let process = processes[pid]
            process.state = .running
            activeProcessor = process.processor
            let processor = activityProcessorIndex(for: process)
            let switchStart = processorBusyTime[processor]
            charge(contextSwitchCost)
            recordActivity(process: process, processor: processor, line: 0,
                           label: "Context switch", kind: .contextSwitch,
                           startTime: switchStart, endTime: processorBusyTime[processor])
            metrics.switches += 1
            let outcome = execute(process, budget: sliceBudget(for: process))
            activeProcessor = nil
            steps += outcome.executed
            updateParallelTimeMetric()
            if let message = outcome.error {
                metrics.processCount = processes.count
                updateParallelTimeMetric()
                return .runtimeError(message)
            }
            if outcome.stoppedForBreakpoint { return .breakpoint(line: stoppedAtLine ?? 0) }
            if outcome.timeLimitExceeded { return .timeLimitExceeded }
            if outcome.cancelled {
                metrics.processCount = processes.count
                updateParallelTimeMetric()
                return .cancelled
            }
        }
    }

    /// Executes at most `maxSteps` statements, for single-stepping in the debugger.
    public func step(maxSteps: Int = 1) -> RunOutcome {
        var executed = 0
        while executed < maxSteps {
            if isCancelled {
                metrics.processCount = processes.count
                metrics.parallelTime = time
                return .cancelled
            }
            // A breakpoint is consumed by the execute loop; clearing it here lets
            // the skipped statement execute when Step/Continue is invoked again.
            stoppedAtLine = nil
            guard let pid = dequeueRunnable() else {
                return finish()
            }
            let process = processes[pid]
            process.state = .running
            activeProcessor = process.processor
            let processor = activityProcessorIndex(for: process)
            let switchStart = processorBusyTime[processor]
            charge(contextSwitchCost)
            recordActivity(process: process, processor: processor, line: 0,
                           label: "Context switch", kind: .contextSwitch,
                           startTime: switchStart, endTime: processorBusyTime[processor])
            metrics.switches += 1
            let remaining = maxSteps - executed
            let outcome = execute(process, budget: min(sliceBudget(for: process), remaining))
            activeProcessor = nil
            executed += outcome.executed
            updateParallelTimeMetric()
            if let message = outcome.error {
                metrics.processCount = processes.count
                updateParallelTimeMetric()
                return .runtimeError(message)
            }
            if outcome.stoppedForBreakpoint { return .breakpoint(line: stoppedAtLine ?? 0) }
            if outcome.timeLimitExceeded { return .timeLimitExceeded }
            if outcome.cancelled {
                metrics.processCount = processes.count
                updateParallelTimeMetric()
                return .cancelled
            }
        }
        return .stepLimitReached
    }

    private var contextSwitchCost: Int {
        metrics.switches == 0 ? 0 : timing.contextSwitch
    }

    private struct StepOutcome {
        var executed = 0
        var error: String?
        var stoppedForBreakpoint = false
        var cancelled = false
        var timeLimitExceeded = false
        var isSuccess: Bool { error == nil && !cancelled }
    }

    private func sliceBudget(for process: Process) -> Int {
        if process.sequential { return Int.max }
        return min(process.slice, timing.contextSwitchLimit)
    }

    private func dequeueRunnable() -> Int? {
        advanceTimeToNextWakeup()
        guard !runQueue.isEmpty else { return nil }
        switch options.policy {
        case .roundRobin, .shortestJobFirst:
            return runQueue.removeFirst()
        case .random where runQueue.count > 1:
            let index = Int(random.next() % UInt64(runQueue.count))
            return runQueue.remove(at: index)
        case .random:
            return runQueue.removeFirst()
        }
    }

    /// Moves the virtual clock forward to the earliest `Duration` expiry.
    private func advanceTimeToNextWakeup() {
        guard runQueue.isEmpty else { return }
        var earliest: Int?
        for process in processes where !process.terminated {
            guard let readyAt = process.readyAt, readyAt > time else { continue }
            if earliest == nil || readyAt < earliest! { earliest = readyAt }
        }
        guard let earliest else { return }
        time = earliest
        for process in processes where !process.terminated && process.readyAt == earliest {
            makeRunnable(process)
        }
    }

    private func finish() -> RunOutcome {
        metrics.processCount = processes.count
        updateParallelTimeMetric()
        let live = processes.filter { !$0.terminated }
        if live.isEmpty { return .completed }
        if live.allSatisfy({ $0.state == .blocked }) {
            metrics.deadlocked = true
            return .deadlock
        }
        return .completed
    }

    // MARK: Scheduling

    func makeRunnable(_ process: Process) {
        process.state = .ready
        process.readyAt = nil
        process.blockReason = nil
        process.waitingOn = nil
        process.resumePending = false
        process.slice = timing.contextSwitchLimit
        runQueue.append(process.id)
    }

    private func block(_ process: Process, _ reason: BlockReason, readyAt: Int?) {
        process.state = .blocked
        process.blockReason = reason
        process.readyAt = readyAt
    }

    func charge(_ amount: Int) {
        let delta = max(0, amount)
        // `time` is the deterministic event-loop clock used by Duration/CLOCK.
        // Parallel elapsed time is reported separately from per-processor work.
        time += delta
        metrics.time = time
        if let processor = activeProcessor, processor >= 0, processor < processorBusyTime.count {
            processorBusyTime[processor] += delta
        }
        updateParallelTimeMetric()
    }

    private func updateParallelTimeMetric() {
        metrics.parallelTime = processorBusyTime.max() ?? 0
    }

    // MARK: Interpreter

    private func execute(_ process: Process, budget: Int) -> StepOutcome {
        var outcome = StepOutcome()
        var steps = 0
        while steps < budget {
            if isCancelled {
                outcome.cancelled = true
                return outcome
            }
            guard let frame = process.frames.last else {
                terminate(process)
                return outcome
            }
            let routine = program.routines[frame.routine]
            guard frame.op < routine.code.count else {
                do {
                    try leaveRoutine(process)
                } catch let suspend as Suspend {
                    process.resumePending = true
                    switch suspend {
                    case .block(let reason, let readyAt): block(process, reason, readyAt: readyAt)
                    }
                    return outcome
                } catch let error as MPWinError {
                    outcome.error = error.description
                    return outcome
                } catch {
                    outcome.error = "\(error)"
                    return outcome
                }
                if process.terminated { return outcome }
                continue
            }

            if process.resumePending {
                process.resumePending = false
            } else {
                let op = routine.code[frame.op]
                let line = frame.op < routine.lines.count ? routine.lines[frame.op] : 0
                if process.skipBreakpointOnce {
                    process.skipBreakpointOnce = false
                } else if line > 0, breakpoints.contains(line) {
                    stoppedAtLine = line
                    process.skipBreakpointOnce = true
                    outcome.stoppedForBreakpoint = true
                    // Keep the process runnable so Continue/Step can resume it.
                    makeRunnable(process)
                    return outcome
                }
                let activityProcessor = activityProcessorIndex(for: process)
                let activityStart = processorBusyTime[activityProcessor]
                do {
                    let frameIndex = beginStatement(process)
                    try step(process, op, line: line)
                    endStatement(process, frameIndex)
                    recordActivity(process: process, processor: activityProcessor, line: line,
                                   label: activityLabel(for: op), kind: .instruction,
                                   startTime: activityStart,
                                   endTime: processorBusyTime[activityProcessor])
                } catch let suspend as Suspend {
                    recordActivity(process: process, processor: activityProcessor, line: line,
                                   label: activityLabel(for: op), kind: .instruction,
                                   startTime: activityStart,
                                   endTime: processorBusyTime[activityProcessor])
                    process.resumePending = true
                    switch suspend {
                    case .block(let reason, let readyAt): block(process, reason, readyAt: readyAt)
                    }
                    return outcome
                } catch Interrupt.cancelled {
                    outcome.cancelled = true
                    return outcome
                } catch Interrupt.timeLimitExceeded {
                    outcome.timeLimitExceeded = true
                    return outcome
                } catch let error as MPWinError {
                    outcome.error = error.description
                    return outcome
                } catch {
                    outcome.error = "\(error)"
                    return outcome
                }
                steps += 1
                outcome.executed = steps
                metrics.executedStatements += 1
                if !process.sequential {
                    let sequentialCost = timing.sequentialCost(of: op)
                    metrics.sequentialTime += sequentialCost
                    process.sequentialTime += sequentialCost
                }
                process.executedStatements += 1
                processorLoad[min(process.processor, processorCount - 1)] += 1
                stepCounter += 1
                if collectProfile {
                    sample(process, line: line)
                }
                if process.terminated { return outcome }
            }
        }
        if !process.sequential {
            process.slice = max(0, process.slice - steps)
            makeRunnable(process)
        }
        return outcome
    }

    private func activityProcessorIndex(for process: Process) -> Int {
        min(max(process.processor, 0), max(processorCount - 1, 0))
    }

    private func recordActivity(process: Process, processor: Int, line: Int,
                                label: String, kind: ProcessorActivityKind,
                                startTime: Int, endTime: Int) {
        guard endTime >= startTime else { return }
        guard processorActivity.count < Self.maximumActivityEvents else {
            activityTraceTruncated = true
            return
        }
        processorActivity.append(ProcessorActivityEvent(
            id: nextActivityEventID,
            processor: processor,
            processID: process.id,
            line: line,
            label: label,
            kind: kind,
            startTime: startTime,
            endTime: endTime))
        nextActivityEventID += 1
    }

    private func activityLabel(for op: Op) -> String {
        switch op {
        case .noop: return "No-op"
        case .declareBlock: return "Declare block"
        case .enterScope: return "Enter scope"
        case .leaveScope: return "Leave scope"
        case .leaveBlock: return "Leave block"
        case .assign: return "Assignment"
        case .call(_, _, let name): return "Call \(name)"
        case .jump: return "Jump"
        case .jumpIfFalse: return "Branch"
        case .forall: return "FORALL"
        case .fork: return "FORK"
        case .spawnEnd: return "Process end"
        case .join: return "JOIN"
        case .duration: return "DURATION"
        case .lock: return "LOCK"
        case .unlock: return "UNLOCK"
        case .seqoff: return "SEQOFF"
        case .seqon: return "SEQON"
        case .read: return "READ"
        case .write: return "WRITE"
        case .newPointer: return "NEW"
        case .dispose: return "DISPOSE"
        }
    }

    private func sample(_ process: Process, line: Int) {
        let step = max(1, timing.activitySampleStep)
        guard stepCounter % step == 0,
              profileSamples.count < Self.maximumProfileSamples else { return }
        profileSamples.append(ProfileSample(time: time, processID: process.id,
                                            processor: process.processor, line: line))
    }

    // MARK: Step dispatch

    func step(_ process: Process, _ op: Op, line: Int) throws {
        switch op {
        case .noop:
            charge(timing.statement)
            advance(process)

        case .declareBlock(let scope, let declarations):
            process.frame.blockMarkers.append(process.frame.slots.count)
            process.frame.scopeMarkers.append(process.frame.scope)
            process.frame.scope = scope
            for (_, type) in declarations {
                process.frame.slots.append(contentsOf: defaultWords(for: type))
            }
            advance(process)

        case .enterScope(let scope):
            process.frame.scopeMarkers.append(process.frame.scope)
            process.frame.scope = scope
            advance(process)

        case .leaveScope:
            if let previous = process.frame.scopeMarkers.popLast() {
                process.frame.scope = previous
            }
            advance(process)

        case .leaveBlock:
            if let marker = process.frame.blockMarkers.popLast() {
                if marker <= process.frame.slots.count {
                    process.frame.slots.removeSubrange(marker..<process.frame.slots.count)
                }
            }
            if let previous = process.frame.scopeMarkers.popLast() {
                process.frame.scope = previous
            }
            advance(process)

        case .jump(let target):
            process.frame.op = target

        case .jumpIfFalse(let condition, let target):
            charge(timing.conditional)
            if try evaluate(condition, process).truthy {
                advance(process)
            } else {
                process.frame.op = target
            }

        case .assign(let target, let value):
            let result = try evaluate(value, process)
            try store(target, result, process)
            charge(timing.statement + timing.copy)
            advance(process)

        case .call(let index, let arguments, _):
            // `performCall` records the caller's next instruction before pushing the callee.
            // Advancing after the push would incorrectly skip the first callee instruction.
            try performCall(process, index, arguments)
            charge(timing.call)

        case .read(let targets, let newline):
            try performRead(process, targets, newline: newline)
            charge(timing.readStatement)
            advance(process)

        case .write(let items, let newline):
            try performWrite(process, items, newline: newline)
            charge(timing.writeStatement)
            advance(process)

        case .duration(let value):
            try performDuration(process, value)
            charge(timing.durationStatement)

        case .lock(let target):
            try performLock(process, target)
            charge(timing.lockAcquire)
            advance(process)

        case .unlock(let target):
            let ref = try address(of: target, process)
            storeLocal(process, ref, value: .boolean(false))
            process.heldLock = nil
            wakeWaitersOn(ref)
            charge(timing.spinlockOperation)
            advance(process)

        case .join:
            try performJoin(process)
            charge(timing.synchronization)
            advance(process)

        case .seqoff:
            process.sequential = true
            charge(timing.synchronization)
            advance(process)

        case .seqon:
            process.sequential = false
            process.slice = timing.contextSwitchLimit
            charge(timing.synchronization)
            advance(process)

        case .forall(let op):
            try performForall(process, op)
            charge(timing.processCreation)

        case .fork(let op):
            try performFork(process, op)
            charge(timing.processCreation)
            advance(process)

        case .spawnEnd:
            try performBodyEnd(process)

        case .newPointer(let target):
            try performNew(process, target)
            charge(timing.newStatement)
            advance(process)

        case .dispose(let target):
            let ref = try address(of: target, process)
            storeLocal(process, ref, value: .pointer(nil))
            charge(timing.disposeStatement)
            advance(process)
        }
    }

    private func advance(_ process: Process) {
        process.frame.op += 1
    }

    /// Starts (or retries) the statement in the innermost frame; returns that frame's index.
    func beginStatement(_ process: Process) -> Int {
        let index = process.frames.count - 1
        process.frames[index].callCursor = 0
        return index
    }

    /// The statement finished, so its recorded call results are no longer needed.
    func endStatement(_ process: Process, _ index: Int) {
        guard index < process.frames.count else { return }
        process.frames[index].callResults.removeAll()
        process.frames[index].callCursor = 0
    }

    /// `Duration n` suspends the process for `n` simulated time units. The wake time is
    /// remembered across the suspend so the retry does not start a new wait.
    private func performDuration(_ process: Process, _ value: Expression) throws {
        if let wakeAt = process.pendingWakeAt {
            guard time >= wakeAt else {
                throw Suspend.block(.duration, readyAt: wakeAt)
            }
            process.pendingWakeAt = nil
            advance(process)
            return
        }
        let units = try evaluate(value, process).asInteger ?? 0
        guard units > 0 else {
            advance(process)
            return
        }
        let (wakeAt, overflow) = time.addingReportingOverflow(units)
        guard !overflow else {
            throw MPWinError.runtime(Diagnostic(.error,
                "Simulated time overflowed the supported integer range.",
                SourceLocation(line: 0, column: 0)))
        }
        process.pendingWakeAt = wakeAt
        throw Suspend.block(.duration, readyAt: wakeAt)
    }

    // MARK: Calls and returns

    func performCall(_ process: Process, _ index: Int, _ arguments: [Argument],
                      returnOffset: Int = 1, callResultIndex: Int? = nil) throws {
        let callee = program.routines[index]
        let returnAddress = Frame.ReturnAddress(routine: process.frame.routine,
                                                op: process.frame.op + returnOffset)
        var slots = [Value?](repeating: nil, count: max(1, callee.localCount))
        var varParams: [MemoryRef] = []
        var frame = Frame(routine: index, op: 0, scope: callee.scope, slots: slots,
                          varParams: varParams)
        var valueCursor = 0
        var varCursor = 0
        for (position, parameter) in callee.parameters.enumerated() {
            let argument = position < arguments.count ? arguments[position] : nil
            switch parameter.binding {
            case .localSlot(let slot, let type):
                guard let argument else { continue }
                let value = try argumentValue(argument, type: type, process: process)
                storeValueInSlots(value, type: type, slots: &slots, at: slot)
                charge(timing.parameter)
                valueCursor += 1
            case .varParam(let index, _):
                guard let argument else { continue }
                let ref = try address(of: argument.value, process)
                while varParams.count <= index { varParams.append(MemoryRef.sharedZero) }
                varParams[index] = ref
                charge(timing.parameter)
                varCursor += 1
            default:
                break
            }
        }
        _ = valueCursor
        _ = varCursor

        frame.slots = slots
        frame.varParams = varParams
        frame.returnAddress = returnAddress
        frame.callResultIndex = callResultIndex
        // Defaults go in after the arguments; this only fills slots that are still empty.
        initializeFrame(&frame, using: callee.scope)
        process.frames.append(frame)
    }

    private func storeValueInSlots(_ value: Value, type: TypeInfo, slots: inout [Value?], at base: Int) {
        guard base < slots.count else { return }
        switch type {
        case .array(let element, let lower, let upper):
            guard case .array(let values) = value else {
                slots[base] = value
                return
            }
            let count = zip(lower, upper).reduce(1) { $0 * max(0, $1.1 - $1.0 + 1) }
            let stride = max(1, element.footprint)
            for index in 0..<min(count, values.count) {
                storeValueInSlots(values[index], type: element, slots: &slots, at: base + index * stride)
            }

        case .record(let fields):
            guard case .record(let values) = value else {
                slots[base] = value
                return
            }
            var offset = 0
            for (index, field) in fields.enumerated() {
                guard index < values.count else { break }
                storeValueInSlots(values[index], type: field.type, slots: &slots, at: base + offset)
                offset += max(1, field.type.footprint)
            }

        default:
            slots[base] = value
        }
    }

    /// A value parameter is copied; a `var` parameter is read at the point of use so the
    /// callee and caller share one location, as the original does.
    private func argumentValue(_ argument: Argument, type: TypeInfo, process: Process) throws -> Value {
        if argument.isVar {
            let ref = try address(of: argument.value, process)
            return try load(ref: ref, type: type, process: process)
        }
        return try evaluate(argument.value, process)
    }

    func leaveRoutine(_ process: Process) throws {
        if let frame = process.frames.last, let back = frame.returnAddress {
            process.frames.removeLast()
            var caller = process.frames[process.frames.count - 1]
            caller.op = back.op
            if let index = frame.callResultIndex, index < caller.callResults.count {
                // A function result lives in the callee's frame, so it is copied out
                // before the frame is discarded. This also covers a function that
                // blocked and finished later, after its statement was abandoned.
                let resultSlot = program.routines[frame.routine].resultSlot
                let value = resultSlot.flatMap { $0 < frame.slots.count ? frame.slots[$0] : nil }
                caller.callResults[index] = Frame.CallResult(value: value ?? .void,
                                                             next: caller.callCursor)
            }
            process.frames[process.frames.count - 1] = caller
            return
        }
        try performBodyEnd(process)
    }

    // MARK: Process spawning

    private func performForall(_ process: Process, _ op: ForallOp) throws {
        // Multi-Pascal FORALL is a synchronizing construct: the parent process
        // is blocked until every child created by this FORALL has terminated.
        // This is distinct from FORK, where the parent continues immediately.
        if let pending = process.waitingForForallChildren {
            let alive = pending.reduce(into: 0) { count, id in
                if id < processes.count && !processes[id].terminated { count += 1 }
            }
            if alive > 0 {
                throw Suspend.block(.forall(remaining: alive), readyAt: nil)
            }
            process.waitingForForallChildren = nil
            advance(process)
            return
        }

        let first = try evaluate(op.initial, process).asInteger ?? 0
        let last = try evaluate(op.final, process).asInteger ?? 0
        guard first <= last else {
            advance(process)
            return
        }
        let grouping = try op.grouping.map { try evaluate($0, process).asInteger ?? 0 }
        if let grouping, grouping <= 1 {
            throw MPWinError.semantic(Diagnostic(.error,
                "The value of GROUPING must be greater than 1.",
                SourceLocation(line: 0, column: 0)))
        }
        let (distance, distanceOverflow) = last.subtractingReportingOverflow(first)
        guard !distanceOverflow else {
            throw MPWinError.runtime(Diagnostic(.error,
                "FORALL range is too large to represent safely.",
                SourceLocation(line: 0, column: 0)))
        }
        let (iterationCount, countOverflow) = distance.addingReportingOverflow(1)
        guard !countOverflow, iterationCount > 0 else {
            throw MPWinError.runtime(Diagnostic(.error,
                "FORALL range is too large to represent safely.",
                SourceLocation(line: 0, column: 0)))
        }
        let groupSize = grouping ?? 1
        if let grouping, grouping > iterationCount {
            throw MPWinError.semantic(Diagnostic(.error,
                "GROUPING cannot exceed the number of FORALL iterations.",
                SourceLocation(line: 0, column: 0)))
        }
        let quotient = iterationCount / groupSize
        let remainder = iterationCount % groupSize
        let childCount = quotient + (remainder == 0 ? 0 : 1)
        guard childCount <= Self.maximumProcessCount - processes.count else {
            throw MPWinError.runtime(Diagnostic(.error,
                "Program exceeded the safety limit of \(Self.maximumProcessCount) simulated processes.",
                SourceLocation(line: 0, column: 0)))
        }

        var childIDs: [Int] = []
        childIDs.reserveCapacity(childCount)
        var groupFirst = first
        while true {
            // Subtract first, then add at most the remaining distance. This avoids
            // overflowing when a legal index range approaches Int.max.
            let remaining = last - groupFirst
            let span = min(groupSize - 1, remaining)
            let (candidateLast, addOverflow) = groupFirst.addingReportingOverflow(span)
            guard !addOverflow else {
                throw MPWinError.runtime(Diagnostic(.error,
                    "FORALL range is too large to represent safely.",
                    SourceLocation(line: 0, column: 0)))
            }
            let groupLast = candidateLast
            // The child must exist before evaluating @/Port expressions so they can
            // reference the FORALL index variable in the child's frame.
            let child = spawnChild(of: process, scope: op.bodyScope,
                                   routine: process.frame.routine, op: op.bodyStart,
                                   homeProcessor: nil, ports: [])
            setSlot(child, op.indexSlot, .integer(groupFirst))
            if let processorExpression = op.processor {
                let requested = try evaluate(processorExpression, child).asInteger ?? child.processor
                child.processor = try validatedProcessor(requested)
            }
            child.ports = try resolvePorts(op.ports, child)
            // Those expressions ran outside any statement of the child; don't let the
            // child's first statement replay their results.
            endStatement(child, 0)
            if groupFirst < groupLast {
                child.forallContinuation = ForallContinuation(
                    nextIndex: groupFirst + 1,
                    lastIndex: groupLast,
                    indexSlot: op.indexSlot,
                    bodyStart: op.bodyStart
                )
            }
            childIDs.append(child.id)
            process.children.append(child.id)
            if groupLast == last { break }
            groupFirst = groupLast + 1
        }

        process.waitingForForallChildren = childIDs
        throw Suspend.block(.forall(remaining: childIDs.count), readyAt: nil)
    }

    private func performFork(_ process: Process, _ op: ForkOp) throws {
        guard processes.count < Self.maximumProcessCount else {
            throw MPWinError.runtime(Diagnostic(.error,
                "Program exceeded the safety limit of \(Self.maximumProcessCount) simulated processes.",
                SourceLocation(line: 0, column: 0)))
        }
        let requested = try op.processor.map {
            try validatedProcessor(try evaluate($0, process).asInteger ?? process.processor)
        }
        let child = spawnChild(of: process, scope: op.bodyScope, routine: process.frame.routine,
                               op: op.bodyStart, homeProcessor: requested, ports: [])
        child.ports = try resolvePorts(op.ports, child)
        endStatement(child, 0)
        process.children.append(child.id)
    }

    private func resolvePorts(_ ports: [Expression], _ process: Process) throws -> [MemoryRef] {
        var refs: [MemoryRef] = []
        for port in ports {
            let ref = try address(of: port, process)
            guard case .channel(let buffer) = try rawLoad(ref: ref, process: process) else { continue }
            buffer.receiverProcess = process.id
            buffer.receiverPortIndex = refs.count
            refs.append(ref)
        }
        if !refs.isEmpty { charge(timing.portSetup) }
        return refs
    }

    /// A child copies the parent's current locals, per the manual.
    private func spawnChild(of parent: Process, scope: Scope, routine: Int, op: Int,
                            homeProcessor: Int?, ports: [MemoryRef]) -> Process {
        // The child's only frame is a copy of the parent's innermost one, so references to
        // that frame are rebased to frame 0. References into the parent's callers keep
        // pointing at the parent's frames, so `var` parameters still reach the caller.
        let parentFrame = parent.frames.count - 1
        let varParams = parent.frame.varParams.map { ref -> MemoryRef in
            guard case .local(let frame) = ref.segment else { return ref }
            let segment: Segment = frame == parentFrame
                ? .local(frame: 0)
                : .processLocal(process: parent.id, frame: frame)
            return MemoryRef(segment: segment, address: ref.address)
        }
        let frame = Frame(routine: routine, op: op, scope: scope,
                          slots: parent.frame.slots,
                          varParams: varParams,
                          blockMarkers: parent.frame.blockMarkers,
                          scopeMarkers: parent.frame.scopeMarkers)
        let id = nextProcessID
        nextProcessID += 1
        let processor = homeProcessor.map { min(max(0, $0), processorCount - 1) }
            ?? chooseProcessor()
        let child = Process(id: id, frame: frame, processor: processor,
                            slice: timing.contextSwitchLimit)
        child.createdAt = time
        child.ports = ports
        processes.append(child)
        runQueue.append(child.id)
        return child
    }

    private func setSlot(_ process: Process, _ slot: Int, _ value: Value) {
        if slot < process.frame.slots.count { process.frame.slots[slot] = value }
    }

    private func validatedProcessor(_ processor: Int) throws -> Int {
        guard processor >= 0, processor < processorCount else {
            throw MPWinError.runtime(Diagnostic(.error, "INVALID PROCESSOR NUMBER", SourceLocation(line: 0, column: 0)))
        }
        return processor
    }

    private func chooseProcessor() -> Int {
        guard processorCount > 1 else { return 0 }
        var occupied = Set<Int>()
        for process in processes where !process.terminated {
            occupied.insert(process.processor)
        }
        for processor in 1..<processorCount where !occupied.contains(processor) {
            return processor
        }
        let candidates = Array(1..<processorCount)
        return candidates.min { lhs, rhs in
            if processorBusyTime[lhs] == processorBusyTime[rhs] { return lhs < rhs }
            return processorBusyTime[lhs] < processorBusyTime[rhs]
        } ?? 0
    }

    private func performJoin(_ process: Process) throws {
        let alive = liveChildren(of: process)
        guard alive > 0 else { return }
        throw Suspend.block(.join(remaining: alive), readyAt: nil)
    }

    private func liveChildren(of process: Process) -> Int {
        process.children.reduce(0) { count, id in
            count + (processes[id].terminated ? 0 : 1)
        }
    }

    /// End of a process body: grouped FORALL children loop back through their assigned
    /// iteration range; normal processes terminate only after their own children finish.
    private func performBodyEnd(_ process: Process) throws {
        if let continuation = process.forallContinuation {
            setSlot(process, continuation.indexSlot, .integer(continuation.nextIndex))
            if continuation.nextIndex < continuation.lastIndex {
                var next = continuation
                // Safe because the branch proves nextIndex < lastIndex.
                next.nextIndex += 1
                process.forallContinuation = next
            } else {
                // Do not increment the last index: it may be Int.max. The final
                // assigned iteration executes once, then this child can terminate.
                process.forallContinuation = nil
            }
            process.frame.op = continuation.bodyStart
            return
        }
        let alive = liveChildren(of: process)
        guard alive > 0 else {
            terminate(process)
            return
        }
        throw Suspend.block(.waitingForChildren(remaining: alive), readyAt: nil)
    }

    private func terminate(_ process: Process) {
        if let held = process.heldLock {
            storeLocal(process, held, value: .boolean(false))
            process.heldLock = nil
            wakeWaitersOn(held)
        }
        process.state = .terminated
        process.blockReason = nil
        process.waitingOn = nil
        process.frames.removeAll()
        // Anyone waiting on this process, or on a channel it can still feed, retries.
        for other in processes where !other.terminated && other.state == .blocked {
            switch other.blockReason {
            case .join, .forall, .waitingForChildren:
                makeRunnable(other)
            case .channelRead:
                if let buffer = other.waitingOn, !buffer.queue.isEmpty { makeRunnable(other) }
            default:
                break
            }
        }
    }

    // MARK: Spinlocks

    private func performLock(_ process: Process, _ target: Expression) throws {
        let ref = try address(of: target, process)
        if try load(ref: ref, type: .spinlock, process: process).truthy {
            charge(timing.spinlockPoll)
            throw Suspend.block(.spinlock(ref), readyAt: nil)
        }
        storeLocal(process, ref, value: .boolean(true))
        process.heldLock = ref
    }

    private func wakeWaitersOn(_ ref: MemoryRef) {
        for other in processes where other.state == .blocked {
            if case .spinlock(let waiting) = other.blockReason, waiting == ref {
                makeRunnable(other)
            }
        }
    }

    // MARK: Channels

    // MARK: Input / output

    private func performWrite(_ process: Process, _ items: [WriteItem], newline: Bool) throws {
        // Format everything before writing: an item can block on a channel, and the retried
        // statement must not print the items before it a second time.
        var text = ""
        for item in items {
            let value = try evaluate(item.value, process)
            let width = try item.width.map { try evaluate($0, process).asInteger ?? 0 }
            let decimals = try item.decimals.map { try evaluate($0, process).asInteger ?? 0 }
            text += Format.write(value, width: width, decimals: decimals)
        }
        if newline { text += "\n" }
        output += text
    }

    func performRead(_ process: Process, _ targets: [Expression], newline: Bool) throws {
        for target in targets {
            let type = staticType(of: target, process)
            if type.isNumeric {
                // Numbers may be separated by blanks and line breaks, as in Pascal.
                skipInputWhitespace(acrossLines: true)
                var token = ""
                if let character = peekInput(), character == "-" || character == "+" {
                    token.append(consumeInput())
                }
                while let character = peekInput(),
                      character.isASCII && (character.isNumber || character == ".") {
                    token.append(consumeInput())
                }
                guard !token.isEmpty else {
                    throw MPWinError.runtime(Diagnostic(.error,
                        "Input expected for numeric value.", target.location))
                }
                if type == .real {
                    guard let value = Double(token) else {
                        throw MPWinError.runtime(Diagnostic(.error,
                            "Invalid real input: \(token)", target.location))
                    }
                    try store(target, .real(value), process)
                } else {
                    guard let value = Int(token) else {
                        throw MPWinError.runtime(Diagnostic(.error,
                            "Invalid integer input: \(token)", target.location))
                    }
                    try store(target, .integer(value), process)
                }
            } else {
                try store(target, .character(consumeInput()), process)
            }
        }
        if newline { skipInputLine() }
    }

    /// True once the input source is exhausted, for the `Eof` function. Being at the end
    /// of the last line counts, so `while not eof do read(x)` stops after the last value.
    var atEndOfInput: Bool {
        inputLine >= inputLines.count
            || (inputLine == inputLines.count - 1 && inputColumn >= inputLines[inputLine].count)
    }

    /// True at the end of the current input line, for the `Eoln` function.
    var atEndOfLine: Bool {
        peekInput() == nil
    }

    private func peekInput() -> Character? {
        guard inputLine < inputLines.count else { return nil }
        let line = inputLines[inputLine]
        guard inputColumn < line.count else { return nil }
        return line[inputColumn]
    }

    private func skipInputWhitespace(acrossLines: Bool) {
        while inputLine < inputLines.count {
            if let character = peekInput() {
                guard character == " " || character == "\t" else { return }
                inputColumn += 1
            } else if acrossLines {
                skipInputLine()
            } else {
                return
            }
        }
    }

    /// Takes the next character. At the end of a line this yields the blank that stands
    /// for the line break and moves to the next line, as Pascal's `Read` of a CHAR does.
    private func consumeInput() -> Character {
        guard let character = peekInput() else {
            skipInputLine()
            return " "
        }
        inputColumn += 1
        return character
    }

    private func skipInputLine() {
        inputColumn = 0
        if inputLine < inputLines.count { inputLine += 1 }
    }

    // MARK: Pointers

    /// `New(p)` always allocates a fresh cell, even when `p` already points somewhere;
    /// other pointers to the old cell keep it.
    private func performNew(_ process: Process, _ target: Expression) throws {
        let ref = try address(of: target, process)
        storeLocal(process, ref, value: .pointer(CellBox(.integer(0))))
    }

    // MARK: Frame initialization

    private func defaultWords(for type: TypeInfo) -> [Value?] {
        switch type {
        case .array(let element, let lower, let upper):
            let count = zip(lower, upper).reduce(1) { $0 * max(0, $1.1 - $1.0 + 1) }
            return Array(repeating: defaultWords(for: element), count: count).flatMap { $0 }.map { $0 }
        case .record(let fields):
            return fields.flatMap { defaultWords(for: $0.type) }
        default:
            return [type.defaultValue]
        }
    }

    private func initializeFrame(_ frame: inout Frame, using scope: Scope) {
        for binding in scope.table.values {
            switch binding {
            case .localSlot(let slot, let type), .functionResult(let slot, let type), .loopIndex(let slot, let type):
                let words = defaultWords(for: type)
                for (offset, value) in words.enumerated() where slot + offset < frame.slots.count {
                    if frame.slots[slot + offset] == nil { frame.slots[slot + offset] = value }
                }
            default:
                continue
            }
        }
    }

    // MARK: Introspection

    public var status: [ProcessStatus] {
        processes.map { process in
            guard let frame = process.frames.last else {
                return ProcessStatus(id: process.id, routineName: "-", lineNumber: 0,
                                     state: process.state, processor: process.processor,
                                     blockReason: process.blockReason, readyAt: process.readyAt)
            }
            let routine = program.routines[frame.routine]
            let line = frame.op < routine.lines.count ? routine.lines[frame.op] : 0
            return ProcessStatus(id: process.id, routineName: routine.name, lineNumber: line,
                                 state: process.state, processor: process.processor,
                                 blockReason: process.blockReason, readyAt: process.readyAt)
        }
    }

    public var isComplete: Bool { processes.allSatisfy(\.terminated) }
    public var profile: [ProfileSample] { profileSamples }
    /// Number of processors the configured architecture provides.
    public var availableProcessors: Int { processorCount }
}

// MARK: - Metrics

public struct Metrics: Sendable {
    public init() {}

    /// Aggregate virtual time used by Clock/diagnostics. It is still maintained
    /// by the interpreter's deterministic event loop.
    public var time = 0
    public var executedStatements = 0
    public var switches = 0
    public var processCount = 0
    public var deadlocked = false
    /// Sum of the sequential costs of every statement executed, for the speedup figure.
    public var sequentialTime = 0
    /// Simulated parallel elapsed time: the busiest processor's accumulated work/cost.
    public var parallelTime = 0

    /// The statistics block, formatted exactly as the original prints it.
    public func report(processorsUsed: Int) -> String {
        var text = "Performance Statistics for Program\n"
        text += "  Sequential Execution Time: \(sequentialTime)\n"
        text += "  Parallel Execution Time: \(parallelTime)\n"
        if parallelTime > 0 {
            text += "  Speedup:  \(String(format: "%.2f", Double(sequentialTime) / Double(parallelTime)))\n"
        } else {
            text += "  Speedup:  0.00\n"
        }
        text += "  Number of Processors Used: \(processorsUsed)\n"
        if deadlocked {
            text += "    DEADLOCK:  All Processes are Blocked\n"
            text += "For Further Information Type STATUS Command\n"
        }
        return text
    }
}

public enum ProcessorActivityKind: String, Sendable, Hashable {
    case instruction
    case contextSwitch
}

/// One simulated operation on a processor's local cost timeline. These are
/// simulator timing units, not host wall-clock timestamps or CPU utilization.
public struct ProcessorActivityEvent: Sendable, Identifiable, Hashable {
    public let id: Int
    public let processor: Int
    public let processID: Int
    public let line: Int
    public let label: String
    public let kind: ProcessorActivityKind
    public let startTime: Int
    public let endTime: Int

    public var duration: Int { max(0, endTime - startTime) }
}

public struct ProfileSample: Sendable {
    public var time: Int
    public var processID: Int
    public var processor: Int
    public var line: Int
}

// MARK: - Random

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
