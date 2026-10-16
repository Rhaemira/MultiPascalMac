// Created by Amirali Yazdani on 10/16/26.
#if canImport(SwiftUI)
import AppKit
import Combine
import Foundation
import MPWinCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MPWinAppModel: ObservableObject {
    enum ResultsTab: String, CaseIterable, Identifiable {
        case output = "Output"
        case processes = "Processes"
        case metrics = "Metrics"
        case activity = "Activity"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .output: return "terminal"
            case .processes: return "person.3.sequence"
            case .metrics: return "speedometer"
            case .activity: return "chart.bar.xaxis"
            case .diagnostics: return "exclamationmark.triangle"
            }
        }
    }

    struct SampleProgram: Identifiable, Hashable {
        let id: String
        let name: String
        let subtitle: String
        let source: String
        let input: String?
        let systemImage: String
    }

    struct SimulationSnapshot: Sendable {
        let machine: Machine
        let outcome: RunOutcome
        let output: String
        let metrics: Metrics
        let processes: [ProcessStatus]
        let processorLoad: [Int]
        let profile: [ProfileSample]
        let processorActivity: [ProcessorActivityEvent]
        let activityTraceTruncated: Bool
    }

    static let starterSource = """
    program ParallelExample;
    Architecture Shared(4);
    var a: array[1..8] of Integer;
    var i: Integer;
    begin
      forall i := 1 to 8 do
        a[i] := i * i;
      writeln(a[1], ' ', a[8]);
    end.
    """

    static let samples: [SampleProgram] = [
        SampleProgram(
            id: "hello",
            name: "Hello Parallel",
            subtitle: "Independent FORALL iterations",
            source: starterSource,
            input: nil,
            systemImage: "sparkles"),
        SampleProgram(
            id: "matrix",
            name: "Parallel Matrix Multiplication",
            subtitle: "Good first parallel algorithm",
            source: """
            program ParallelMatrixMultiplication;
            Architecture Shared(4);

            const
              N = 8;

            type
              Matrix = array[1..N, 1..N] of Integer;

            var
              A, B, C: Matrix;
              i, j, k: Integer;
              CheckSum: Integer;

            begin
              for i := 1 to N do
                for j := 1 to N do
                  A[i, j] := i + j;

              for i := 1 to N do
                for j := 1 to N do
                  B[i, j] := i - j;

              forall i := 1 to N do
              begin
                for j := 1 to N do
                begin
                  C[i, j] := 0;
                  for k := 1 to N do
                    C[i, j] := C[i, j] + A[i, k] * B[k, j];
                end;
              end;

              CheckSum := 0;
              for i := 1 to N do
                for j := 1 to N do
                  CheckSum := CheckSum + C[i, j];

              writeln('C[1,1]   = ', C[1,1]);
              writeln('C[8,8]   = ', C[8,8]);
              writeln('Checksum = ', CheckSum);
            end.
            """,
            input: nil,
            systemImage: "square.grid.3x3.topleft.filled"),
        SampleProgram(
            id: "ranksort",
            name: "RankSort · Input",
            subtitle: "Parallel rank calculation with user input",
            source: """
            program RankSortInput;
            Architecture Shared(4);

            const
              N = 8;

            type
              ArrType = array[1..N] of Integer;

            var
              A, Sorted: ArrType;
              Rank: array[1..N] of Integer;
              i, j: Integer;

            begin
              writeln('Enter ', N, ' integers:');
              for i := 1 to N do
                read(A[i]);

              forall i := 1 to N do
              begin
                Rank[i] := 1;
                for j := 1 to N do
                  if (A[j] < A[i]) or
                     ((A[j] = A[i]) and (j < i)) then
                    Rank[i] := Rank[i] + 1;
              end;

              forall i := 1 to N do
                Sorted[Rank[i]] := A[i];

              writeln('Sorted:');
              for i := 1 to N do
                Write(Sorted[i], ' ');
              WriteLn;
            end.
            """,
            input: nil,
            systemImage: "arrow.up.arrow.down") ,
        SampleProgram(
            id: "processors",
            name: "Processor Placement",
            subtitle: "Map each FORALL iteration to a processor",
            source: """
            program ProcessorPlacement;
            Architecture Shared(4);
            var
              A: array[0..3] of Integer;
              i: Integer;
            begin
              forall i := 0 to 3 do (@i)
                A[i] := %SELF;
              writeln(A[0], ' ', A[1], ' ', A[2], ' ', A[3]);
            end.
            """,
            input: nil,
            systemImage: "cpu") ,
        SampleProgram(
            id: "channels",
            name: "Channel Communication",
            subtitle: "FORK + channel + JOIN",
            source: """
            program Channels;
            Architecture Shared(2);
            var
              C: Channel of Integer;
              X: Integer;
            begin
              fork C := 42;
              X := C;
              writeln('Received: ', X);
              join;
            end.
            """,
            input: nil,
            systemImage: "arrow.left.arrow.right")
    ]

    @Published var source: String = MPWinAppModel.starterSource {
        didSet {
            if !suppressDirtyTracking { isDirty = true }
        }
    }
    @Published private(set) var isDirty = false
    @Published private(set) var fileURL: URL?
    @Published private(set) var documentName = "Untitled"
    @Published private(set) var compiledProgram: CompiledProgram?
    @Published private(set) var machine: Machine?
    @Published private(set) var output = ""
    @Published private(set) var diagnostics = ""
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var metrics = Metrics()
    @Published private(set) var processes: [ProcessStatus] = []
    @Published private(set) var processorLoad: [Int] = []
    @Published private(set) var profile: [ProfileSample] = []
    @Published private(set) var processorActivity: [ProcessorActivityEvent] = []
    @Published private(set) var activityTraceTruncated = false
    @Published private(set) var lastOutcome: RunOutcome?
    @Published private(set) var isRunning = false

    @Published var selectedTab: ResultsTab = .output
    @Published var breakpointText = ""
    @Published var breakpoints: Set<Int> = []
    @Published var showingParameters = false
    @Published var showingAbout = false
    @Published var showingInput = false
    @Published var inputText = ""
    @Published private(set) var inputSourceName: String?
    @Published var options = ProgramOptions()

    private var suppressDirtyTracking = false
    private var operationID = UUID()
    private var cancellationToken: SimulationCancellation?

    var sourceLineCount: Int {
        max(1, source.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    var executableLineCount: Int { compiledProgram?.executableLines.count ?? 0 }

    var architectureText: String {
        guard let architecture = compiledProgram?.architecture else { return "No architecture" }
        let count = architecture.topology.processorCount(parameter: architecture.parameter)
        return "\(architecture.topology.rawValue)(\(architecture.parameter)) · \(count) processors"
    }

    var fileDisplayName: String {
        if documentName.isEmpty { return "Untitled" }
        return documentName
    }

    var usedProcessorCount: Int {
        guard !processes.isEmpty else { return 0 }
        return Set(processes.map(\.processor)).count
    }

    var hasCompiledProgram: Bool { compiledProgram != nil && !isDirty }

    // MARK: Compilation / execution

    @discardableResult
    func compile() -> Bool {
        invalidateExecution(clearMachine: true)
        do {
            var parser = try Parser(source: source)
            let unit = try parser.parseProgram()
            let program = try Loader.load(unit)
            compiledProgram = program
            breakpoints = Set(breakpoints.filter { program.executableLines.contains($0) })
            diagnostics = ""
            statusMessage = "Compiled · \(program.executableLines.count) executable lines"
            isDirty = false
            selectedTab = .output
            return true
        } catch {
            compiledProgram = nil
            diagnostics = format(error: error)
            statusMessage = "Compilation failed"
            selectedTab = .diagnostics
            return false
        }
    }

    func run() {
        guard !isRunning else { return }
        if compiledProgram == nil || isDirty {
            guard compile() else { return }
        }
        guard let program = compiledProgram else { return }
        if program.requiresInput && options.input == nil {
            inputText = ""
            inputSourceName = nil
            showingInput = true
            statusMessage = "Waiting for input"
            selectedTab = .output
            return
        }
        startBackgroundRun(program: program, machine: nil)
    }

    func runWithInput() {
        guard !isRunning, compiledProgram != nil else { return }
        options.input = inputText
        inputSourceName = "Console input"
        showingInput = false
        startBackgroundRun(program: compiledProgram!, machine: nil)
    }

    func continueRun() {
        guard !isRunning else { return }
        if case .cancelled? = lastOutcome {
            run()
            return
        }
        if let machine {
            startBackgroundRun(program: machine.program, machine: machine)
        } else {
            run()
        }
    }

    func step() {
        guard !isRunning else { return }
        if compiledProgram == nil || isDirty {
            guard compile() else { return }
        }
        guard let program = compiledProgram else { return }
        let current: Machine
        if let machine {
            current = machine
        } else {
            let token = SimulationCancellation()
            cancellationToken = token
            current = Machine(program: program, options: options, cancellation: token)
            current.start()
            machine = current
        }
        current.breakpoints = breakpoints
        let outcome = current.step()
        apply(snapshot: SimulationSnapshot(
            machine: current,
            outcome: outcome,
            output: current.output,
            metrics: current.metrics,
            processes: current.status,
            processorLoad: current.processorLoad,
            profile: current.profile,
            processorActivity: current.processorActivity,
            activityTraceTruncated: current.activityTraceTruncated))
        statusMessage = outcomeStatus(outcome)
    }

    func reset() {
        operationID = UUID()
        cancellationToken?.cancel()
        cancellationToken = nil
        isRunning = false
        machine = nil
        output = ""
        diagnostics = ""
        metrics = Metrics()
        processes = []
        processorLoad = []
        profile = []
        processorActivity = []
        activityTraceTruncated = false
        lastOutcome = nil
        statusMessage = compiledProgram == nil ? "Ready" : "Program reset"
        selectedTab = .output
    }

    func addBreakpoint() {
        guard let line = Int(breakpointText.trimmingCharacters(in: .whitespacesAndNewlines)), line > 0 else { return }
        guard compiledProgram?.executableLines.contains(line) == true else {
            diagnostics = "Line \(line) is not an executable line in the current program."
            selectedTab = .diagnostics
            return
        }
        breakpoints.insert(line)
        breakpointText = ""
        machine?.breakpoints = breakpoints
        statusMessage = "Breakpoint added · line \(line)"
    }

    func removeBreakpoint(_ line: Int) {
        breakpoints.remove(line)
        machine?.breakpoints = breakpoints
    }

    func clearBreakpoints() {
        breakpoints.removeAll()
        machine?.breakpoints.removeAll()
        statusMessage = "Breakpoints cleared"
    }

    func stop() {
        guard isRunning else { return }
        cancellationToken?.cancel()
        statusMessage = "Stopping…"
    }

    // MARK: Documents / samples

    func newFile() {
        operationID = UUID()
        suppressDirtyTracking = true
        source = Self.starterSource
        suppressDirtyTracking = false
        isDirty = false
        fileURL = nil
        documentName = "Untitled"
        clearInput()
        compiledProgram = nil
        reset()
        statusMessage = "New document"
    }

    func openSample(_ sample: SampleProgram) {
        operationID = UUID()
        suppressDirtyTracking = true
        source = sample.source
        suppressDirtyTracking = false
        isDirty = false
        fileURL = nil
        documentName = sample.name
        compiledProgram = nil
        inputSourceName = nil
        inputText = sample.input ?? ""
        options.input = sample.input
        reset()
        statusMessage = "Loaded sample · \(sample.name)"
    }

    func openSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = sourceFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSource(url: url)
    }

    func loadSource(url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            suppressDirtyTracking = true
            source = text
            suppressDirtyTracking = false
            isDirty = false
            fileURL = url
            documentName = url.lastPathComponent
            reset()
            statusMessage = "Opened · \(url.lastPathComponent)"
        } catch {
            diagnostics = error.localizedDescription
            selectedTab = .diagnostics
            statusMessage = "Could not open file"
        }
    }

    func saveSource() {
        if let url = fileURL {
            writeSource(to: url)
            return
        }
        saveSourceAs()
    }

    func saveSourceAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [mpfType, .plainText]
        panel.nameFieldStringValue = (documentName == "Untitled" ? "Untitled" : URL(fileURLWithPath: documentName).deletingPathExtension().lastPathComponent) + ".mpf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeSource(to: url)
    }

    // MARK: Input

    func openInputSheet() {
        if inputText.isEmpty, let value = options.input { inputText = value }
        showingInput = true
    }

    func loadInputFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "in") ?? .plainText,
                                     UTType(filenameExtension: "dat") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            inputText = text
            options.input = text
            inputSourceName = url.lastPathComponent
            statusMessage = "Input loaded · \(url.lastPathComponent)"
        } catch {
            diagnostics = error.localizedDescription
            selectedTab = .diagnostics
        }
    }

    func clearInput() {
        inputText = ""
        options.input = nil
        inputSourceName = nil
        statusMessage = "Input source cleared"
    }

    // MARK: Parameters / log

    func applyTiming(_ timing: TimingModel) {
        guard !isRunning else { return }
        cancellationToken?.cancel()
        cancellationToken = nil
        options.timing = timing
        machine = nil
        statusMessage = "Parameters applied"
    }

    func applySimulationSettings(timeLimitText: String, policy: SchedulingPolicy, seedText: String,
                                 timing: TimingModel) {
        let trimmed = timeLimitText.trimmingCharacters(in: .whitespacesAndNewlines)
        options.timeLimit = Int(trimmed).flatMap { $0 > 0 ? $0 : nil }
        options.policy = policy
        if let seed = UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            options.seed = seed
        }
        applyTiming(timing)
    }

    func resetParametersToDefaults() {
        options = ProgramOptions()
        machine = nil
        statusMessage = "Parameters reset to defaults"
    }

    func saveLogFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MultiPascal-Log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = output + "\n\n" + metrics.report(processorsUsed: maxUsedProcessorCount())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Log saved"
        } catch {
            diagnostics = error.localizedDescription
            selectedTab = .diagnostics
        }
    }

    // MARK: Helpers

    private var mpfType: UTType {
        UTType(filenameExtension: "mpf") ?? .plainText
    }

    private var sourceFileTypes: [UTType] {
        [mpfType, .plainText, UTType(filenameExtension: "pas") ?? .plainText,
         UTType(filenameExtension: "pascal") ?? .plainText]
    }

    private func startBackgroundRun(program: CompiledProgram, machine existingMachine: Machine?) {
        let opID = UUID()
        operationID = opID
        isRunning = true
        statusMessage = existingMachine == nil ? "Running…" : "Continuing…"
        selectedTab = .output
        diagnostics = ""
        let configuredBreakpoints = breakpoints
        let configuredOptions = options
        let token = existingMachine == nil ? SimulationCancellation() : cancellationToken
        if existingMachine == nil { cancellationToken = token }
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                let current = existingMachine ?? Machine(program: program, options: configuredOptions, cancellation: token)
                current.breakpoints = configuredBreakpoints
                current.collectProfile = true
                if existingMachine == nil { current.start() }
                let outcome = current.run()
                return SimulationSnapshot(
                    machine: current,
                    outcome: outcome,
                    output: current.output,
                    metrics: current.metrics,
                    processes: current.status,
                    processorLoad: current.processorLoad,
                    profile: current.profile,
                    processorActivity: current.processorActivity,
                    activityTraceTruncated: current.activityTraceTruncated)
            }.value
            guard operationID == opID else { return }
            apply(snapshot: snapshot)
            isRunning = false
            cancellationToken = nil
            statusMessage = outcomeStatus(snapshot.outcome)
            switch snapshot.outcome {
            case .deadlock:
                selectedTab = .processes
            case .runtimeError, .timeLimitExceeded:
                selectedTab = .diagnostics
            default:
                break
            }
        }
    }

    private func apply(snapshot: SimulationSnapshot) {
        machine = snapshot.machine
        output = snapshot.output
        metrics = snapshot.metrics
        processes = snapshot.processes
        processorLoad = snapshot.processorLoad
        profile = snapshot.profile
        processorActivity = snapshot.processorActivity
        activityTraceTruncated = snapshot.activityTraceTruncated
        lastOutcome = snapshot.outcome
        diagnostics = snapshot.outcome.diagnosticText
    }

    private func invalidateExecution(clearMachine: Bool) {
        cancellationToken?.cancel()
        cancellationToken = nil
        isRunning = false
        output = ""
        diagnostics = ""
        metrics = Metrics()
        processes = []
        processorLoad = []
        profile = []
        processorActivity = []
        activityTraceTruncated = false
        lastOutcome = nil
        if clearMachine { machine = nil }
    }

    private func writeSource(to url: URL) {
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            documentName = url.lastPathComponent
            isDirty = false
            statusMessage = "Saved · \(url.lastPathComponent)"
        } catch {
            diagnostics = error.localizedDescription
            selectedTab = .diagnostics
        }
    }

    private func format(error: Error) -> String {
        guard let error = error as? MPWinError else { return error.localizedDescription }
        var text = error.description
        let lineNumber = error.location.line
        let column = error.location.column
        let lines = source.components(separatedBy: .newlines)
        guard lineNumber > 0, lineNumber <= lines.count else { return text }
        let sourceLine = lines[lineNumber - 1]
        let safeColumn = max(1, min(column == 0 ? 1 : column, sourceLine.count + 1))
        let spaces = String(repeating: " ", count: safeColumn - 1)
        text += "\n\n\(lineNumber) │ \(sourceLine)\n    │ \(spaces)^"
        return text
    }

    private func maxUsedProcessorCount() -> Int {
        usedProcessorCount
    }

    private func outcomeStatus(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .completed: return "Completed"
        case .breakpoint(let line): return "Breakpoint · line \(line)"
        case .timeLimitExceeded: return "Stopped · time alarm exceeded"
        case .deadlock: return "Stopped · deadlock detected"
        case .stepLimitReached: return "Step complete"
        case .cancelled: return "Stopped"
        case .runtimeError: return "Runtime error"
        }
    }
}

private extension RunOutcome {
    var diagnosticText: String {
        switch self {
        case .runtimeError(let message): return message
        case .deadlock:
            return "All currently live processes are blocked. Open Processes to inspect their wait states."
        case .timeLimitExceeded:
            return "The configured time alarm was reached before the program completed."
        default:
            return ""
        }
    }
}
#endif
