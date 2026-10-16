// Created by Amirali Yazdani on 10/16/26.
#if canImport(SwiftUI)
import AppKit
import Foundation
import MPWinCore
import SwiftUI

private enum MPTheme {
    static let blue = Color(red: 0.18, green: 0.43, blue: 1.00)
    static let purple = Color(red: 0.55, green: 0.27, blue: 0.95)
    static let mint = Color(red: 0.13, green: 0.72, blue: 0.58)
    static let orange = Color(red: 0.95, green: 0.56, blue: 0.16)
    static let red = Color(red: 0.92, green: 0.23, blue: 0.30)
    static let panel = Color.primary.opacity(0.045)
    static let border = Color.primary.opacity(0.10)
}

struct ContentView: View {
    @ObservedObject var model: MPWinAppModel

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            Divider()
            if shouldShowQuickStart {
                quickStartBanner
                Divider()
            }
            mainWorkspace
            Divider()
            statusBar
        }
        .animation(.easeInOut(duration: 0.16), value: shouldShowQuickStart)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showingParameters) {
            ParametersView(model: model)
        }
        .sheet(isPresented: $model.showingInput) {
            InputView(model: model)
        }
        .sheet(isPresented: $model.showingAbout) {
            AboutView()
        }
    }

    private var shouldShowQuickStart: Bool {
        model.lastOutcome == nil && model.output.isEmpty && model.diagnostics.isEmpty
    }

    /// A lightweight onboarding strip that disappears when the user gets a result
    /// or a compiler diagnostic. It gives first-time users an obvious next action.
    private var quickStartBanner: some View {
        HStack(spacing: 10) {
            Label("Quick start", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MPTheme.blue)
            Rectangle().fill(MPTheme.border).frame(width: 1, height: 18)
            quickStep("1", "Edit source")
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            quickStep("2", "Compile · ⌘F9")
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            quickStep("3", "Run · F9")
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            Text("Explore Output, Processes and Activity below")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MPTheme.blue.opacity(0.055))
    }

    private func quickStep(_ number: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(MPTheme.blue)
                .frame(width: 17, height: 17)
                .background(MPTheme.blue.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }

    private var appHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [MPTheme.blue, MPTheme.purple],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Multi-Pascal")
                            .font(.headline.weight(.semibold))
                        Text(model.fileDisplayName + (model.isDirty ? " · Unsaved" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                architecturePill
                statusPill
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                actionButton("Compile", systemImage: "hammer.fill", tint: MPTheme.blue,
                             shortcut: KeyEquivalent("\u{F70C}"), modifiers: [.command]) {
                    _ = model.compile()
                }
                .disabled(model.isRunning)

                actionButton("Run", systemImage: "play.fill", tint: MPTheme.mint,
                             shortcut: KeyEquivalent("\u{F70C}"), modifiers: []) {
                    model.run()
                }
                .disabled(model.isRunning)

                actionButton("Stop", systemImage: "stop.fill", tint: MPTheme.red) {
                    model.stop()
                }
                .disabled(!model.isRunning)

                actionButton("Continue", systemImage: "forward.fill", tint: MPTheme.purple) {
                    model.continueRun()
                }
                .disabled(model.isRunning || model.machine == nil)

                actionButton("Step", systemImage: "arrow.right.to.line", tint: MPTheme.orange,
                             shortcut: KeyEquivalent("\u{F70A}"), modifiers: []) {
                    model.step()
                }
                .disabled(model.isRunning)

                actionButton("Reset", systemImage: "arrow.counterclockwise", tint: .secondary) {
                    model.reset()
                }
                .disabled(model.isRunning)

                Spacer(minLength: 10)

                Menu {
                    Button("New Document", systemImage: "doc.badge.plus") { model.newFile() }
                    Button("Open…", systemImage: "folder") { model.openSource() }
                    Divider()
                    Button("Save", systemImage: "square.and.arrow.down") { model.saveSource() }
                    Button("Save As…", systemImage: "square.and.arrow.down.on.square") { model.saveSourceAs() }
                } label: {
                    Label("File", systemImage: "doc")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.bordered)

                Menu {
                    ForEach(MPWinAppModel.samples) { sample in
                        Button {
                            model.openSample(sample)
                        } label: {
                            Label {
                                Text(sample.name)
                            } icon: {
                                Image(systemName: sample.systemImage)
                            }
                        }
                    }
                } label: {
                    Label("Samples", systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.bordered)

                Button {
                    model.openInputSheet()
                } label: {
                    Label("Input", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
                .tint(MPTheme.purple)
                .help(model.inputSourceName == nil ? "Enter or load program input" : "Edit current input")

                Button {
                    model.showingParameters = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Simulation parameters")

                Button {
                    model.showingAbout = true
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
    }

    private var architecturePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
            Text(model.architectureText)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(MPTheme.border))
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRunning ? MPTheme.orange : (model.lastOutcome?.isFailure == true ? MPTheme.red : MPTheme.mint))
                .frame(width: 7, height: 7)
            Text(model.statusMessage)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((model.isRunning ? MPTheme.orange : (model.lastOutcome?.isFailure == true ? MPTheme.red : MPTheme.mint)).opacity(0.12), in: Capsule())
    }

    private func actionButton(_ title: String, systemImage: String, tint: Color,
                              shortcut: KeyEquivalent? = nil, modifiers: EventModifiers = [],
                              action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
        }
        .controlSize(.regular)
        .help(actionHelp(for: title))
        let styledButton: AnyView
        if title == "Compile" || title == "Run" {
            styledButton = AnyView(button.buttonStyle(.borderedProminent).tint(tint))
        } else {
            styledButton = AnyView(button.buttonStyle(.bordered).tint(tint))
        }
        if let shortcut {
            return AnyView(styledButton.keyboardShortcut(shortcut, modifiers: modifiers))
        }
        return styledButton
    }

    private func actionHelp(for title: String) -> String {
        switch title {
        case "Compile": return "Check the source and build the simulator's executable representation (⌘F9)."
        case "Run": return "Run the program from the beginning (F9)."
        case "Stop": return "Request that the current simulation stop (Esc)."
        case "Continue": return "Continue the paused simulation, or restart after cancellation."
        case "Step": return "Execute one simulation step (F7)."
        case "Reset": return "Clear execution state and return to the Output view."
        default: return title
        }
    }

    private var mainWorkspace: some View {
        VSplitView {
            HSplitView {
                sourcePane
                    .frame(minWidth: 620, idealWidth: 820)
                inspectorPane
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 360)
            }
            .frame(minHeight: 430)

            resultsPane
                .frame(minHeight: 250)
        }
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(MPTheme.blue)
                    Text("Source")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Text("\(model.sourceLineCount) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("MPWin · Pascal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(MPTheme.panel)

            Divider()

            PascalCodeEditor(text: SwiftUI.Binding(
                get: { model.source },
                set: { model.source = $0 }
            ))
        }
        .background(.background)
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorCard(title: "Program", icon: "doc.text", tint: MPTheme.blue) {
                    InspectorRow(title: "Document", value: model.fileDisplayName)
                    InspectorRow(title: "Status", value: model.statusMessage)
                    InspectorRow(title: "Architecture", value: model.architectureText)
                    InspectorRow(title: "Executable lines", value: "\(model.executableLineCount)")
                }

                inspectorCard(title: "Input", icon: "keyboard", tint: MPTheme.purple) {
                    HStack(spacing: 10) {
                        Image(systemName: model.inputSourceName == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .foregroundStyle(model.inputSourceName == nil ? .secondary : MPTheme.mint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.inputSourceName ?? "No input loaded")
                                .font(.subheadline.weight(.medium))
                            Text(model.compiledProgram?.requiresInput == true ? "This program reads input." : "Input is optional for the current program.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("Enter / Edit") { model.openInputSheet() }
                            .buttonStyle(.bordered)
                        Button("Load File…") { model.loadInputFile() }
                            .buttonStyle(.bordered)
                    }
                }

                inspectorCard(title: "Breakpoints", icon: "circle.fill", tint: MPTheme.orange) {
                    HStack(spacing: 7) {
                        TextField("Line", text: $model.breakpointText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(model.addBreakpoint)
                        Button {
                            model.addBreakpoint()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MPTheme.orange)
                    }

                    if model.breakpoints.isEmpty {
                        Text("No breakpoints")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(model.breakpoints.sorted(), id: \.self) { line in
                                HStack {
                                    Circle().fill(MPTheme.orange).frame(width: 7, height: 7)
                                    Text("Line \(line)")
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Button {
                                        model.removeBreakpoint(line)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        Button("Clear all") { model.clearBreakpoints() }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.borderless)
                    }
                }

                inspectorCard(title: "Live state", icon: "waveform.path.ecg", tint: MPTheme.mint) {
                    InspectorRow(title: "Simulated time", value: "\(model.metrics.time)")
                    InspectorRow(title: "Processes", value: "\(model.metrics.processCount)")
                    InspectorRow(title: "Used processors", value: "\(model.usedProcessorCount)")
                }
            }
            .padding(14)
        }
        .background(MPTheme.panel)
    }

    private func inspectorCard<Content: View>(title: String, icon: String, tint: Color,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            content()
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MPTheme.border))
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(MPWinAppModel.ResultsTab.allCases) { tab in
                    resultTab(tab)
                }
                Spacer()
                if !model.output.isEmpty {
                    Button {
                        model.saveLogFile()
                    } label: {
                        Label("Save Log", systemImage: "square.and.arrow.down")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(MPTheme.panel)

            Divider()

            ZStack {
                switch model.selectedTab {
                case .output:
                    OutputView(text: model.output, onCompile: { _ = model.compile() }, onRun: { model.run() })
                case .processes:
                    ProcessTableView(processes: model.processes)
                case .metrics:
                    MetricsView(model: model)
                case .activity:
                    ActivityView(model: model)
                case .diagnostics:
                    DiagnosticsView(text: model.diagnostics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private func resultTab(_ tab: MPWinAppModel.ResultsTab) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) {
                model.selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                Text(tab.rawValue)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.selectedTab == tab ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(model.selectedTab == tab ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRunning ? MPTheme.orange : (model.lastOutcome?.isFailure == true ? MPTheme.red : MPTheme.mint))
                    .frame(width: 7, height: 7)
                Text(model.statusMessage)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))

            Spacer()

            if model.inputSourceName != nil {
                Label(model.inputSourceName!, systemImage: "keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("MPWin dialect · virtual processor timing · F7 Step · Esc Stop")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

struct InspectorRow: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

struct OutputView: View {
    let text: String
    let onCompile: () -> Void
    let onRun: () -> Void

    var body: some View {
        Group {
            if text.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 20)
                    Image(systemName: "terminal")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(MPTheme.blue)
                        .frame(width: 70, height: 70)
                        .background(MPTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Text("Your program output appears here")
                        .font(.headline)
                    Text("Compile to check your source, then run to see WRITE and WRITELN results.\nIf the program asks for input, Multi-Pascal will open the input panel for you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 450)
                    HStack(spacing: 10) {
                        Button(action: onCompile) {
                            Label("Compile", systemImage: "hammer.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(MPTheme.blue)
                        Button(action: onRun) {
                            Label("Run program", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MPTheme.mint)
                    }
                    .padding(.top, 3)
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
    }
}

struct DiagnosticsView: View {
    let text: String
    var body: some View {
        Group {
            if text.isEmpty {
                EmptyStateView(title: "All clear", message: "Compiler and runtime diagnostics will appear here.", systemImage: "checkmark.circle.fill", tint: MPTheme.mint)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Diagnostic", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(MPTheme.red)
                        Text(text)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(MPTheme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct ProcessTableView: View {
    let processes: [ProcessStatus]
    var body: some View {
        if processes.isEmpty {
            EmptyStateView(title: "No processes", message: "Run or step a program to inspect the simulated process tree.", systemImage: "person.3.sequence")
        } else {
            Table(processes) {
                TableColumn("ID") { Text("P\($0.id)").font(.system(.caption, design: .monospaced)) }
                    .width(min: 55, ideal: 65)
                TableColumn("Procedure") { Text($0.routineName).font(.system(.caption, design: .monospaced)) }
                TableColumn("Line") { Text("\($0.lineNumber)").monospacedDigit() }
                    .width(min: 50, ideal: 55)
                TableColumn("State") { StateBadge(state: $0.state) }
                TableColumn("Processor") { Text("P\($0.processor)").monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("Waiting") {
                    Text($0.blockReason?.description ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

struct StateBadge: View {
    let state: ProcessState
    var tint: Color {
        switch state {
        case .ready: return MPTheme.blue
        case .running: return MPTheme.mint
        case .preempted: return MPTheme.orange
        case .blocked: return MPTheme.purple
        case .terminated: return .secondary
        }
    }
    var body: some View {
        Text(state.statusText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.11), in: Capsule())
    }
}

struct MetricsView: View {
    @ObservedObject var model: MPWinAppModel

    private var speedup: Double? {
        guard model.metrics.parallelTime > 0, model.metrics.sequentialTime > 0 else { return nil }
        return Double(model.metrics.sequentialTime) / Double(model.metrics.parallelTime)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12)], spacing: 12) {
                    MetricCard(title: "Speedup", value: speedup.map { String(format: "%.2f×", $0) } ?? "—", caption: "Sequential ÷ parallel", icon: "gauge.with.dots.needle.50percent", tint: MPTheme.blue)
                    MetricCard(title: "Simulated parallel time", value: "\(model.metrics.parallelTime)", caption: "Busiest virtual processor", icon: "clock", tint: MPTheme.mint)
                    MetricCard(title: "Sequential time", value: "\(model.metrics.sequentialTime)", caption: "Estimated serial work", icon: "arrow.left.arrow.right", tint: MPTheme.purple)
                    MetricCard(title: "Processors", value: "\(model.usedProcessorCount)", caption: "Actually used", icon: "cpu", tint: MPTheme.orange)
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Performance summary")
                            .font(.headline)
                        Text("Deterministic simulator · virtual processor timing, not native CPU benchmarking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.metrics.report(processorsUsed: model.usedProcessorCount))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run state")
                            .font(.headline)
                        Label(model.lastOutcome == .completed ? "Completed" : (model.lastOutcome == nil ? "Not run" : "See diagnostics"),
                              systemImage: model.lastOutcome == .completed ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(model.lastOutcome == .completed ? MPTheme.mint : .secondary)
                        Text("Statements: \(model.metrics.executedStatements)")
                        Text("Context switches: \(model.metrics.switches)")
                    }
                    .font(.caption)
                    .frame(width: 190, alignment: .leading)
                    .padding(14)
                    .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let caption: String
    let icon: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Spacer()
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: icon).font(.caption).foregroundStyle(tint))
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tint.opacity(0.16)))
    }
}

struct ActivityView: View {
    @ObservedObject var model: MPWinAppModel

    private var events: [ProcessorActivityEvent] { model.processorActivity }
    private var processorCount: Int { max(model.processorLoad.count, 1) }
    private var timelineEnd: Int { max(events.map(\.endTime).max() ?? 0, 1) }
    private var activeProcessorCount: Int {
        Set(events.filter { $0.kind == .instruction }.map(\.processor)).count
    }
    private var processorWork: [Int] {
        var totals = [Int](repeating: 0, count: processorCount)
        for event in events where event.processor >= 0 && event.processor < totals.count {
            totals[event.processor] = max(totals[event.processor], event.endTime)
        }
        return totals
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.processorLoad.isEmpty && events.isEmpty {
                    EmptyStateView(title: "No activity", message: "Processor activity appears after a run.", systemImage: "chart.bar.xaxis")
                } else {
                    Text("Processor activity")
                        .font(.headline)

                    HStack(spacing: 10) {
                        ActivityMetric(title: "Processors active", value: "\(activeProcessorCount)", detail: "of \(processorCount)")
                        ActivityMetric(title: "Instruction events", value: "\(events.filter { $0.kind == .instruction }.count)", detail: "recorded")
                        ActivityMetric(title: "Local timeline", value: "\(timelineEnd)", detail: "simulated units")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Relative processor workload")
                                    .font(.headline)
                                Text("Accumulated simulated cost · busiest processor = 100%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        VStack(spacing: 10) {
                            let work = processorWork
                            let maximum = max(work.max() ?? 1, 1)
                            ForEach(Array(model.processorLoad.enumerated()), id: \.offset) { index, load in
                                let relative = Int((Double(work[index]) / Double(maximum) * 100).rounded())
                                HStack(spacing: 10) {
                                    Text("P\(index)")
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .frame(width: 34, alignment: .leading)
                                    GeometryReader { proxy in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(MPTheme.panel)
                                            Capsule()
                                                .fill(LinearGradient(colors: [MPTheme.blue, MPTheme.purple], startPoint: .leading, endPoint: .trailing))
                                                .frame(width: proxy.size.width * CGFloat(work[index]) / CGFloat(maximum))
                                        }
                                    }
                                    .frame(height: 10)
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text("\(relative)%")
                                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        Text("\(load) ops")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 66, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Processor timeline")
                                    .font(.headline)
                                Text("Each lane shows the operations actually scheduled on that processor.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 10) {
                                ActivityLegend(color: MPTheme.blue, title: "Process work (color by ID)")
                                ActivityLegend(color: MPTheme.orange, title: "Switch overhead")
                            }
                        }

                        if events.isEmpty {
                            Text("No trace events were recorded for this run.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 18)
                        } else {
                            ProcessorTimelineCanvas(events: events, processorCount: processorCount, maxTime: timelineEnd)
                                .frame(height: CGFloat(processorCount) * 36 + 42)
                        }

                        Text("The horizontal scale is processor-local simulated cost time. These are not host CPU measurements, and this visual is MPWin-inspired rather than a pixel-for-pixel reproduction of the original Windows graph.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if model.activityTraceTruncated {
                        Label("The timeline reached its 50,000-event safety cap. The shown trace covers the beginning of execution.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }

                    if !events.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent activity events")
                                .font(.headline)
                            ForEach(Array(events.suffix(60).reversed()), id: \.id) { event in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(event.kind == .contextSwitch ? MPTheme.orange : MPTheme.blue)
                                        .frame(width: 4, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("P\(event.processor) · Process \(event.processID) · \(event.label)")
                                            .font(.system(.caption, design: .monospaced).weight(.medium))
                                        Text(event.line > 0 ? "Source line \(event.line)" : "Scheduler overhead")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(event.startTime) → \(event.endTime)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(14)
                        .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if !model.profile.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Profile samples")
                                .font(.headline)
                            ForEach(Array(model.profile.suffix(100).enumerated()), id: \.offset) { _, sample in
                                HStack {
                                    Text("t=\(sample.time)")
                                    Text("process \(sample.processID)")
                                    Text("P\(sample.processor)")
                                    Text("line \(sample.line)")
                                }
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct ActivityMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MPTheme.border))
    }
}

private struct ActivityLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ProcessorTimelineCanvas: View {
    let events: [ProcessorActivityEvent]
    let processorCount: Int
    let maxTime: Int

    private var eventsByProcessor: [Int: [ProcessorActivityEvent]] {
        Dictionary(grouping: events, by: \.processor)
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let labelWidth: CGFloat = 42
                let topPadding: CGFloat = 24
                let laneHeight: CGFloat = 36
                let plotWidth = max(1, size.width - labelWidth - 8)
                let effectiveMax = CGFloat(max(maxTime, 1))
                let scale = plotWidth / effectiveMax
                let laneBottom = topPadding + CGFloat(max(processorCount, 1)) * laneHeight

                for tick in 0...4 {
                    let value = Int((Double(maxTime) * Double(tick) / 4.0).rounded())
                    let x = labelWidth + CGFloat(value) * scale
                    var grid = Path()
                    grid.move(to: CGPoint(x: x, y: topPadding - 3))
                    grid.addLine(to: CGPoint(x: x, y: laneBottom))
                    context.stroke(grid, with: .color(Color.secondary.opacity(0.18)), lineWidth: 1)
                    context.draw(
                        Text("\(value)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                        at: CGPoint(x: x, y: 10), anchor: .center)
                }

                for processor in 0..<max(processorCount, 1) {
                    let laneY = topPadding + CGFloat(processor) * laneHeight
                    context.draw(
                        Text("P\(processor)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(.secondary),
                        at: CGPoint(x: 19, y: laneY + 13), anchor: .center)
                    let laneRect = CGRect(x: labelWidth, y: laneY + 3, width: plotWidth, height: 22)
                    context.fill(Path(roundedRect: laneRect, cornerRadius: 4), with: .color(Color.secondary.opacity(0.06)))

                    for event in eventsByProcessor[processor] ?? [] {
                        let x = labelWidth + CGFloat(max(0, event.startTime)) * scale
                        let eventWidth: CGFloat = event.duration == 0 ? 2 : max(2, CGFloat(event.duration) * scale)
                        let availableWidth = max(0, labelWidth + plotWidth - x)
                        guard availableWidth > 0 else { continue }
                        let rect = CGRect(x: x, y: laneY + 5, width: min(eventWidth, availableWidth), height: 18)
                        let color = timelineColor(for: event)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.88)))
                        if rect.width > 52 && event.kind == .instruction {
                            context.draw(
                                Text(event.line > 0 ? "P\(event.processID) L\(event.line) \(event.label)" : event.label)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white),
                                at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func timelineColor(for event: ProcessorActivityEvent) -> Color {
        guard event.kind == .instruction else { return MPTheme.orange }
        let palette: [Color] = [
            MPTheme.blue, MPTheme.purple, MPTheme.mint,
            Color(red: 0.82, green: 0.30, blue: 0.54),
            Color(red: 0.20, green: 0.65, blue: 0.82),
            Color(red: 0.65, green: 0.55, blue: 0.20)
        ]
        return palette[max(0, event.processID) % palette.count]
    }
}

struct ParametersView: View {
    @ObservedObject var model: MPWinAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var timing: TimingModel
    @State private var timeLimit = ""
    @State private var policy: SchedulingPolicy
    @State private var seed = ""

    init(model: MPWinAppModel) {
        self.model = model
        _timing = State(initialValue: model.options.timing)
        _timeLimit = State(initialValue: model.options.timeLimit.map(String.init) ?? "")
        _policy = State(initialValue: model.options.policy)
        _seed = State(initialValue: String(model.options.seed))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulation Parameters")
                        .font(.title2.weight(.bold))
                    Text("Tune scheduling and simulated operation costs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Defaults") {
                    timing = TimingModel()
                    timeLimit = ""
                    policy = .roundRobin
                    seed = String(ProgramOptions().seed)
                }
                .buttonStyle(.bordered)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ParameterSection(title: "Scheduler", systemImage: "arrow.triangle.2.circlepath", tint: MPTheme.blue) {
                        ParameterPickerRow(title: "Policy", selection: $policy)
                        ParameterTextRow(title: "Time alarm", placeholder: "Optional", text: $timeLimit)
                        ParameterTextRow(title: "Random seed", placeholder: "Unsigned integer", text: $seed)
                    }

                    ParameterSection(title: "Process", systemImage: "person.2", tint: MPTheme.purple) {
                        ParameterStepperRow(title: "Creation time", value: $timing.processCreation, range: 0...1000)
                        ParameterStepperRow(title: "Context-switch limit", value: $timing.contextSwitchLimit, range: 1...1_000_000)
                        ParameterStepperRow(title: "Context-switch time", value: $timing.contextSwitch, range: 0...1000)
                    }

                    ParameterSection(title: "Communication", systemImage: "arrow.left.arrow.right", tint: MPTheme.mint) {
                        ParameterStepperRow(title: "Channel operation", value: $timing.channelOperation, range: 0...1000)
                        ParameterStepperRow(title: "Link delay", value: $timing.linkDelay, range: 0...1000)
                        ParameterStepperRow(title: "Port setup", value: $timing.portSetup, range: 0...1000)
                    }

                    ParameterSection(title: "Statement costs", systemImage: "function", tint: MPTheme.orange) {
                        ParameterStepperRow(title: "Statement", value: $timing.statement, range: 0...1000)
                        ParameterStepperRow(title: "Conditional", value: $timing.conditional, range: 0...1000)
                        ParameterStepperRow(title: "Write", value: $timing.writeStatement, range: 0...1000)
                        ParameterStepperRow(title: "Read", value: $timing.readStatement, range: 0...1000)
                    }

                    ParameterSection(title: "Profiling", systemImage: "waveform.path", tint: MPTheme.red) {
                        ParameterStepperRow(title: "Profile sample step", value: $timing.profileSampleStep, range: 1...10_000)
                        ParameterStepperRow(title: "Activity sample step", value: $timing.activitySampleStep, range: 1...10_000)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    model.applySimulationSettings(timeLimitText: timeLimit, policy: policy, seedText: seed, timing: timing)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(MPTheme.blue)
            }
            .padding(16)
        }
        .frame(width: 620, height: 700)
    }
}

struct ParameterSection<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(title).font(.subheadline.weight(.semibold))
            }
            content
        }
        .padding(14)
        .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ParameterPickerRow: View {
    let title: String
    @SwiftUI.Binding var selection: SchedulingPolicy
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(SchedulingPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 190)
        }
    }
}

struct ParameterTextRow: View {
    let title: String
    let placeholder: String
    @SwiftUI.Binding var text: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
        }
    }
}

struct ParameterStepperRow: View {
    let title: String
    @SwiftUI.Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: $value, in: range) {
                Text("\(value)")
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .controlSize(.small)
        }
    }
}

struct InputView: View {
    @ObservedObject var model: MPWinAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Program Input")
                        .font(.title2.weight(.bold))
                    Text("Enter values separated by spaces or new lines, or load an input file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let name = model.inputSourceName {
                    Label(name, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            TextEditor(text: $model.inputText)
                .font(.system(size: 13, design: .monospaced))
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(MPTheme.panel)
                .padding(12)

            HStack(spacing: 8) {
                Button("Load File…") { model.loadInputFile() }
                    .buttonStyle(.bordered)
                Button("Clear") { model.clearInput() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Input") {
                    model.runWithInput()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(MPTheme.purple)
                .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 650, height: 520)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let iconURL = Bundle.main.url(forResource: "AppIconPreview", withExtension: "png")
                    ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
                   let iconImage = NSImage(contentsOf: iconURL) {
                    Image(nsImage: iconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [MPTheme.blue, MPTheme.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Multi-Pascal Mac")
                .font(.title.weight(.bold))
            Text("A native macOS implementation of the Multi-Pascal teaching simulator.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Compile Pascal, run FORALL/FORK programs, inspect simulated processors and processes, experiment with timing, and explore processor activity.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Label("⌘F9  Compile source", systemImage: "hammer.fill")
                Label("F9  Run from the start", systemImage: "play.fill")
                Label("F7  Execute one step", systemImage: "arrow.right.to.line")
                Label("Activity  Inspect simulated processor work", systemImage: "chart.bar.xaxis")
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(MPTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Created by Amirali Yazdani · Version 1.1")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Timing is simulated and is not a native CPU benchmark.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(MPTheme.blue)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 430)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    var tint: Color = .secondary
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct MultiPascalCommands: Commands {
    @ObservedObject var model: MPWinAppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { model.newFile() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { model.openSource() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Save") { model.saveSource() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { model.saveSourceAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandMenu("Run") {
            Button("Compile") { _ = model.compile() }
                .keyboardShortcut(KeyEquivalent("\u{F70C}"), modifiers: [.command])
            Button("Run") { model.run() }
                .keyboardShortcut(KeyEquivalent("\u{F70C}"), modifiers: [])
            Button("Continue") { model.continueRun() }
            Button("Step") { model.step() }
                .keyboardShortcut(KeyEquivalent("\u{F70A}"), modifiers: [])
            Divider()
            Button("Stop") { model.stop() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Reset") { model.reset() }
        }

        CommandMenu("Input") {
            Button("Enter / Edit Input") { model.openInputSheet() }
            Button("Load Input File…") { model.loadInputFile() }
            Button("Clear Input") { model.clearInput() }
        }

        CommandMenu("Samples") {
            ForEach(MPWinAppModel.samples) { sample in
                Button(sample.name) { model.openSample(sample) }
            }
        }

        CommandMenu("Debug") {
            Button("Add Breakpoint") { model.addBreakpoint() }
            Button("Clear Breakpoints") { model.clearBreakpoints() }
        }

        CommandMenu("View") {
            ForEach(MPWinAppModel.ResultsTab.allCases) { tab in
                Button(tab.rawValue) { model.selectedTab = tab }
            }
        }

        CommandMenu("Settings") {
            Button("Simulation Parameters") { model.showingParameters = true }
        }

        CommandGroup(replacing: .help) {
            Button("Multi-Pascal Mac Help") { model.showingAbout = true }
        }
    }
}
#endif
