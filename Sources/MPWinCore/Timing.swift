// Created by Amirali Yazdani on 10/16/26.
import Foundation

/// Simulator cost parameters. Every duration the original charges for an operation lives
/// here, because the exact per-statement model in `MPWinP.exe` could not be recovered.
public struct TimingModel: Sendable, Equatable {
    /// Cost of creating a process (default 5).
    public var processCreation: Int = 5
    /// Context-switch limit — steps a process runs before it may be preempted (default 50).
    public var contextSwitchLimit: Int = 50
    /// Cost of a context switch (default 5).
    public var contextSwitch: Int = 5
    /// Cost of a channel read or write (default 3).
    public var channelOperation: Int = 3
    /// Communication link delay, applied once per processor hop (default 10).
    public var linkDelay: Int = 10
    /// Cost of acquiring or releasing a spinlock.
    public var spinlockOperation: Int = 3
    /// Cost of a `Lock` that has to wait: charged per poll attempt.
    public var spinlockPoll: Int = 1
    /// Cost of an uncontended `Lock`.
    public var lockAcquire: Int = 1
    /// Cost of `Join`, `Seqoff` and `Seqon`.
    public var synchronization: Int = 1
    /// Cost of an `Allocate`/`Port` port connection.
    public var portSetup: Int = 2
    /// Cost of a data-dependent branch.
    public var conditional: Int = 1
    /// Base cost charged once for every executed statement.
    public var statement: Int = 1
    /// Cost of a call, excluding parameter transfer.
    public var call: Int = 2
    /// Cost of transferring one parameter value.
    public var parameter: Int = 1
    /// Cost of one word copied by an assignment, assignment, or `Read`/`Write`.
    public var copy: Int = 1
    /// Fixed costs for the built-in statements.
    public var readStatement: Int = 5
    public var writeStatement: Int = 5
    public var durationStatement: Int = 0
    public var newStatement: Int = 5
    public var disposeStatement: Int = 2
    /// Profile sampling: minimum steps between profile samples (default 20).
    public var profileSampleStep: Int = 20
    /// Minimum steps between process-activity samples (default 10).
    public var activitySampleStep: Int = 10

    public init() {}

    /// Runs without timing, useful for deterministic unit tests.
    public static let free: TimingModel = {
        var model = TimingModel()
        model.processCreation = 0
        model.contextSwitchLimit = 10_000_000
        model.contextSwitch = 0
        model.channelOperation = 0
        model.linkDelay = 0
        model.spinlockOperation = 0
        model.spinlockPoll = 0
        model.lockAcquire = 0
        model.synchronization = 0
        model.portSetup = 0
        model.conditional = 0
        model.statement = 0
        model.call = 0
        model.parameter = 0
        model.copy = 0
        model.readStatement = 0
        model.writeStatement = 0
        model.durationStatement = 0
        model.newStatement = 0
        model.disposeStatement = 0
        model.profileSampleStep = Int.max
        model.activitySampleStep = Int.max
        return model
    }()

    /// Sequential-time cost of one statement, used for the reported sequential total.
    public func sequentialCost(of op: Op) -> Int {
        switch op {
        case .assign: return statement + copy
        case .call: return call
        case .jump: return 0
        case .jumpIfFalse: return conditional
        case .read: return readStatement
        case .write: return writeStatement
        case .duration: return durationStatement
        case .newPointer: return newStatement
        case .dispose: return disposeStatement
        case .lock: return lockAcquire
        case .unlock: return spinlockOperation
        case .join, .seqoff, .seqon: return synchronization
        case .forall, .fork, .spawnEnd: return processCreation
        case .declareBlock, .enterScope, .leaveScope, .leaveBlock, .noop: return 0
        }
    }

    /// Parallel-time cost charged to the running process for one statement.
    public func parallelCost(of op: Op) -> Int {
        switch op {
        case .forall, .fork:
            return processCreation
        case .spawnEnd:
            return 0
        default:
            return sequentialCost(of: op)
        }
    }
}

// MARK: - Scheduler policy

public enum SchedulingPolicy: Sendable, CaseIterable, Hashable {
    case roundRobin
    case random
    case shortestJobFirst

    public var displayName: String {
        switch self {
        case .roundRobin: return "Round-Robin"
        case .random: return "Random"
        case .shortestJobFirst: return "Shortest-Job-First"
        }
    }
}

// MARK: - Program options

public struct ProgramOptions: Sendable {
    /// Simulator timing parameters.
    public var timing: TimingModel
    public var policy: SchedulingPolicy
    /// Upper bound on simulated time units; the run stops if it is exceeded.
    public var timeLimit: Int?
    /// Optional input file replacing the built-in input source.
    public var input: String?
    public var seed: UInt64

    public init(timing: TimingModel = TimingModel(),
                policy: SchedulingPolicy = .roundRobin,
                timeLimit: Int? = nil,
                input: String? = nil,
                seed: UInt64 = 0x5EED_1234) {
        self.timing = timing
        self.policy = policy
        self.timeLimit = timeLimit
        self.input = input
        self.seed = seed
    }
}
