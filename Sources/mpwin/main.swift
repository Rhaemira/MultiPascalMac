// Created by Amirali Yazdani on 10/16/26.
import Foundation
import MPWinCore

@inline(__always)
func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

struct CLI {
    let arguments: [String]

    func run() -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") || arguments.count == 1 {
            printHelp()
            return 0
        }

        do {
            let sourcePath = arguments[1]
            let source = try String(contentsOf: URL(fileURLWithPath: sourcePath), encoding: .utf8)
            var options = ProgramOptions()
            var freeTiming = false
            var index = 2

            while index < arguments.count {
                switch arguments[index] {
                case "--input":
                    guard index + 1 < arguments.count else { return usageError("Missing value for --input") }
                    let path = arguments[index + 1]
                    if path == "-" {
                        options.input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    } else {
                        options.input = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                    }
                    index += 2
                case "--time-limit":
                    guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                        return usageError("--time-limit expects a positive integer")
                    }
                    options.timeLimit = value
                    index += 2
                case "--free":
                    freeTiming = true
                    index += 1
                case "--policy":
                    guard index + 1 < arguments.count, let policy = parsePolicy(arguments[index + 1]) else {
                        return usageError("--policy expects round-robin, random, or shortest-job-first")
                    }
                    options.policy = policy
                    index += 2
                case "--seed":
                    guard index + 1 < arguments.count, let value = UInt64(arguments[index + 1]) else {
                        return usageError("--seed expects an unsigned integer")
                    }
                    options.seed = value
                    index += 2
                default:
                    return usageError("Unknown option: \(arguments[index])")
                }
            }

            if freeTiming { options.timing = .free }

            var parser = try Parser(source: source)
            let unit = try parser.parseProgram()
            let program = try Loader.load(unit)
            let machine = Machine(program: program, options: options)
            machine.start()
            let outcome = machine.run()

            if !machine.output.isEmpty { print(machine.output, terminator: "") }
            print("\n--- Performance Statistics ---")
            print(machine.metrics.report(processorsUsed: Set(machine.status.map(\.processor)).count))

            switch outcome {
            case .completed:
                return 0
            case .breakpoint(let line):
                writeError("Breakpoint hit at line \(line).\n")
                return 2
            case .timeLimitExceeded:
                writeError("Time alarm exceeded.\n")
                return 2
            case .deadlock:
                writeError("DEADLOCK: all live processes are blocked.\n")
                return 3
            case .stepLimitReached:
                writeError("Step limit reached.\n")
                return 2
            case .cancelled:
                writeError("Simulation cancelled.\n")
                return 2
            case .runtimeError(let message):
                writeError("Runtime error: \(message)\n")
                return 4
            }
        } catch {
            writeError("Error: \(error)\n")
            return 1
        }
    }

    private func parsePolicy(_ value: String) -> SchedulingPolicy? {
        switch value.lowercased() {
        case "round-robin", "roundrobin", "rr": return .roundRobin
        case "random": return .random
        case "shortest-job-first", "shortest", "sjf": return .shortestJobFirst
        default: return nil
        }
    }

    private func usageError(_ message: String) -> Int32 {
        writeError("Error: \(message)\n\n")
        printHelp()
        return 64
    }

    private func printHelp() {
        print("""
        Multi-Pascal Mac command-line runner

        Usage:
          mpwin <program.mpf> [options]

        Options:
          --input <file|->       Load READ/READLN input; use - for stdin.
          --time-limit <n>       Stop when simulated time reaches n.
          --policy <policy>      round-robin, random, or shortest-job-first.
          --seed <n>             Set deterministic scheduler/variation seed.
          --free                 Disable simulated timing costs.
          -h, --help             Show this help.

        Example:
          mpwin Samples/HelloParallel.mpf
        """)
    }
}

exit(CLI(arguments: CommandLine.arguments).run())
