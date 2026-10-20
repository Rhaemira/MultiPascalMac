// Created by Amirali Yazdani on 10/16/26.
import Foundation

/// Address resolution, memory access and expression evaluation.
///
/// Every location is a `MemoryRef`: a shared-memory address, a slot in the running
/// process's frame, or a location inside a dereferenced pointer cell. Reading a
/// channel-typed location is a channel read, so a blocking read simply throws
/// `Suspend` and the statement is retried when the process wakes.
extension Machine {
    // MARK: - Static types

    /// The type an expression denotes, used to decide channel reads and numeric coercion.
    func staticType(of expression: Expression, _ process: Process) -> TypeInfo {
        switch expression {
        case .integerLiteral: return .integer
        case .realLiteral: return .real
        case .booleanLiteral: return .boolean
        case .stringLiteral: return .character
        case .nilLiteral: return .pointer(.integer)

        case .identifier(let name, _):
            guard let binding = process.frame.scope.lookup(name) else {
                // An unbound name can still be a parameterless function call.
                guard let index = program.routine(named: name).first else { return .integer }
                return program.routines[index].resultType
            }
            return type(of: binding)

        case .index(let base, let subscripts, _):
            return staticType(of: base, process).droppingDimensions(subscripts.count)

        case .fieldAccess(let base, let name, _):
            return staticType(of: base, process).field(named: name)?.type ?? .integer

        case .dereference(let inner, _):
            let type = staticType(of: inner, process)
            if case .pointer(let target) = type { return target }
            return .integer

        case .unary(let op, _, _) where op == "chan?":
            return .boolean

        case .unary(_, let inner, _):
            return staticType(of: inner, process)

        case .binary(let op, let lhs, let rhs, _):
            if op == "=" || op == "<>" || op == "<" || op == "<=" || op == ">" || op == ">=" {
                return .boolean
            }
            if op == "and" || op == "or" || op == "xor" {
                let leftType = staticType(of: lhs, process)
                let rightType = staticType(of: rhs, process)
                return leftType == .boolean && rightType == .boolean ? .boolean : .integer
            }
            return staticType(of: lhs, process).isReal || staticType(of: rhs, process).isReal
                ? .real : .integer

        case .builtinCall(let builtin, let arguments, _):
            switch builtin {
            case .abs, .sqr:
                return arguments.first.map { staticType(of: $0, process) } ?? .integer
            case .odd, .eof, .eoln: return .boolean
            case .ord, .round, .trunc: return .integer
            case .succ, .pred:
                guard let argument = arguments.first else { return .integer }
                let argumentType = staticType(of: argument, process)
                return argumentType == .character || argumentType == .boolean ? argumentType : .integer
            case .chr: return .character
            case .sin, .cos, .exp, .ln, .sqrt, .arctan: return .real
            case .selfProcess, .myid, .seqtime: return .integer
            case .clock: return .real
            }

        case .call(let name, _, _):
            guard let index = program.routine(named: name).first else { return .integer }
            return program.routines[index].resultType
        }
    }

    private func type(of binding: Binding) -> TypeInfo {
        switch binding {
        case .global(_, let type), .constant(_, let type), .localSlot(_, let type),
             .varParam(_, let type), .functionResult(_, let type), .loopIndex(_, let type):
            return type
        case .typeAlias:
            return .integer
        }
    }

    // MARK: - Addresses

    /// The location an assignable expression denotes.
    func address(of expression: Expression, _ process: Process) throws -> MemoryRef {
        switch expression {
        case .identifier(let name, let location):
            guard let binding = process.frame.scope.lookup(name) else {
                throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", location))
            }
            switch binding {
            case .global(let ref, _): return ref
            case .localSlot(let slot, _), .functionResult(let slot, _), .loopIndex(let slot, _):
                return .localSlot(slot, frame: process.frames.count - 1)
            case .varParam(let index, _):
                guard index < process.frame.varParams.count else {
                    throw MPWinError.semantic(Diagnostic(.error,
                        "Error in the indicated expression.", location))
                }
                let ref = process.frame.varParams[index]
                if case .local = ref.segment, frameIndex(of: ref, process) == nil {
                    // A FORALL/FORK child only has a copy of its parent's innermost frame,
                    // so a caller's local variable passed by reference is out of reach.
                    throw MPWinError.runtime(Diagnostic(.error,
                        "VAR parameter \(name) refers to a local variable of a calling routine, which a spawned process cannot access.",
                        location))
                }
                return ref
            case .constant:
                throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", location))
            case .typeAlias:
                throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", location))
            }

        case .index(let base, let subscripts, let location):
            let baseRef = try address(of: base, process)
            let baseType = staticType(of: base, process)
            guard case .array = baseType else {
                // `p^[i]`: index through a pointer.
                if case .pointer = baseType {
                    guard let first = subscripts.first else {
                        throw MPWinError.semantic(Diagnostic(.error,
                            "An index expression requires at least one subscript.", location))
                    }
                    let index = try evaluate(first, process).asInteger ?? 0
                    guard index >= 0 && index < Self.maximumPointerCells else {
                        throw MPWinError.runtime(Diagnostic(.error,
                            "Pointer index is outside the supported memory safety limit.", location))
                    }
                    let (displacement, overflow) = index.multipliedReportingOverflow(by: baseType.footprint)
                    guard !overflow else {
                        throw MPWinError.runtime(Diagnostic(.error,
                            "Pointer index arithmetic overflowed.", location))
                    }
                    return try offset(try address(of: .dereference(base, location), process),
                                      by: displacement)
                }
                throw MPWinError.semantic(Diagnostic(.error,
                    "Error in the indicated expression.", location))
            }
            var zeroBased: [Int] = []
            var type = baseType
            for (dimension, indexExpression) in subscripts.enumerated() {
                guard case .array(_, let lower, let upper) = type else { break }
                let raw = try evaluate(indexExpression, process).asInteger ?? 0
                let low = lower[0]
                let high = upper[0]
                guard raw >= low && raw <= high else {
                    throw MPWinError.runtime(Diagnostic(.error,
                        "Subscript \(raw) is out of range; expected \(low)..\(high) on dimension \(dimension + 1)",
                        location))
                }
                zeroBased.append(raw - low)
                type = type.slicedType
            }
            guard let linearOffset = baseType.linearOffset(zeroBased) else {
                throw MPWinError.runtime(Diagnostic(.error,
                    "Subscript is out of range", location))
            }
            return try offset(baseRef, by: linearOffset)

        case .fieldAccess(let base, let name, let location):
            let baseRef = try address(of: base, process)
            guard let field = staticType(of: base, process).field(named: name) else {
                throw MPWinError.semantic(Diagnostic(.error,
                    "Error in the indicated expression.", location))
            }
            return try offset(baseRef, by: field.offset)

        case .dereference(let inner, let location):
            let pointer = try evaluate(inner, process)
            switch pointer {
            case .pointer(let box?): return MemoryRef(segment: .cell(box), address: 0)
            case .pointer(nil):
                throw MPWinError.runtime(Diagnostic(.error,
                    "Attempt to dereference a nil pointer", location))
            default:
                throw MPWinError.semantic(Diagnostic(.error,
                    "Error in the indicated expression.", location))
            }

        default:
            throw MPWinError.semantic(Diagnostic(.error,
                "Error in Variable Name", expression.location))
        }
    }

    private func offset(_ ref: MemoryRef, by amount: Int) throws -> MemoryRef {
        let (address, overflow) = ref.address.addingReportingOverflow(amount)
        guard !overflow else {
            throw MPWinError.runtime(Diagnostic(.error,
                "Memory address arithmetic overflowed.", SourceLocation(line: 0, column: 0)))
        }
        return MemoryRef(segment: ref.segment, address: address)
    }

    // MARK: - Loading and storing

    func load(ref: MemoryRef, type: TypeInfo, process: Process) throws -> Value {
        // A channel-typed location reads from the channel, which may block.
        if case .channelOf = type {
            guard case .channel(let buffer) = try rawLoad(ref: ref, process: process) else {
                throw MPWinError.runtime(Diagnostic(.error,
                    "Attempt to read a channel that is not initialised",
                    SourceLocation(line: 0, column: 0)))
            }
            return try readChannel(buffer, ref: ref, process: process)
        }
        return try aggregate(ref: ref, type: type, process: process)
    }

    private func aggregate(ref: MemoryRef, type: TypeInfo, process: Process) throws -> Value {
        switch type {
        case .array(let element, let lower, let upper):
            var values: [Value] = []
            let count = zip(lower, upper).reduce(1) { $0 * max(0, $1.1 - $1.0 + 1) }
            let stride = max(1, element.footprint)
            for index in 0..<count {
                let elementRef = MemoryRef(segment: ref.segment, address: ref.address + index * stride)
                values.append(try aggregate(ref: elementRef, type: element, process: process))
            }
            return .array(values)
        case .record(let fields):
            var values: [Value] = []
            for field in fields {
                let fieldRef = MemoryRef(segment: ref.segment, address: ref.address + field.offset)
                values.append(try aggregate(ref: fieldRef, type: field.type, process: process))
            }
            return .record(values)
        default:
            return try rawLoad(ref: ref, process: process)
        }
    }

    /// The index into `process.frames` a local reference denotes, when that frame exists.
    func frameIndex(of ref: MemoryRef, _ process: Process) -> Int? {
        guard case .local(let frame) = ref.segment,
              frame >= 0, frame < process.frames.count else { return nil }
        return frame
    }

    func rawLoad(ref: MemoryRef, process: Process) throws -> Value {
        switch ref.segment {
        case .shared:
            guard ref.address >= 0, ref.address < sharedMemory.count,
                  let value = sharedMemory[ref.address] else {
                return .void
            }
            return value
        case .local:
            guard let frame = frameIndex(of: ref, process),
                  ref.address >= 0, ref.address < process.frames[frame].slots.count,
                  let value = process.frames[frame].slots[ref.address] else {
                return .void
            }
            return value
        case .cell(let box):
            return box[ref.address] ?? .void
        }
    }

    func rawStore(ref: MemoryRef, value: Value) {
        switch ref.segment {
        case .shared:
            if ref.address >= 0 && ref.address < sharedMemory.count {
                sharedMemory[ref.address] = value
            }
        case .cell(let box):
            box[ref.address] = value
        case .local:
            break
        }
    }

    /// Stores into a process-local slot, or into shared/pointer memory for other references.
    func storeLocal(_ process: Process, _ ref: MemoryRef, value: Value) {
        guard case .local = ref.segment else {
            rawStore(ref: ref, value: value)
            return
        }
        guard let frame = frameIndex(of: ref, process),
              ref.address >= 0 && ref.address < Self.maximumPointerCells else { return }
        // Mutate in place: copying the slot array on every store made large local
        // arrays quadratic to fill.
        if process.frames[frame].slots.count <= ref.address {
            process.frames[frame].slots.append(contentsOf:
                repeatElement(nil, count: ref.address - process.frames[frame].slots.count + 1))
        }
        process.frames[frame].slots[ref.address] = value
    }

    func storeGlobal(_ ref: MemoryRef, type: TypeInfo, value: Value) {
        switch type {
        case .array(let element, let lower, let upper):
            guard case .array(let values) = value else { break }
            let count = zip(lower, upper).reduce(1) { $0 * max(0, $1.1 - $1.0 + 1) }
            let stride = max(1, element.footprint)
            for index in 0..<min(count, values.count) {
                storeGlobal(MemoryRef(segment: .shared, address: ref.address + index * stride),
                            type: element, value: values[index])
            }
            return
        case .record(let fields):
            guard case .record(let values) = value else { break }
            for (index, field) in fields.enumerated() where index < values.count {
                storeGlobal(MemoryRef(segment: .shared, address: ref.address + field.offset),
                            type: field.type, value: values[index])
            }
            return
        default:
            break
        }
        rawStore(ref: ref, value: value)
    }

    /// Assignment: `target := value`, including whole array/record copies and channel sends.
    func store(_ target: Expression, _ value: Value, _ process: Process) throws {
        let ref = try address(of: target, process)
        let type = staticType(of: target, process)
        try store(ref: ref, type: type, value: value, target: target, process: process)
    }

    func store(ref: MemoryRef, type: TypeInfo, value: Value, target: Expression,
               process: Process) throws {
        if case .channelOf = type {
            guard case .channel(let buffer) = try rawLoad(ref: ref, process: process) else {
                throw MPWinError.runtime(Diagnostic(.error,
                    "Attempt to write to a channel that is not initialised", target.location))
            }
            sendChannel(buffer, value: value, ref: ref, target: target)
            return
        }
        let coerced = try coerce(value, to: type, at: target.location)
        switch type {
        case .array(let element, let lower, let upper):
            guard case .array(let values) = coerced else { break }
            let count = zip(lower, upper).reduce(1) { $0 * max(0, $1.1 - $1.0 + 1) }
            let stride = max(1, element.footprint)
            for index in 0..<min(count, values.count) {
                let elementRef = MemoryRef(segment: ref.segment, address: ref.address + index * stride)
                try store(ref: elementRef, type: element, value: values[index], target: target,
                          process: process)
            }
            return
        case .record(let fields):
            guard case .record(let values) = coerced else { break }
            for (index, field) in fields.enumerated() where index < values.count {
                let fieldRef = MemoryRef(segment: ref.segment, address: ref.address + field.offset)
                try store(ref: fieldRef, type: field.type, value: values[index], target: target,
                          process: process)
            }
            return
        case .spinlock:
            storeLocal(process, ref, value: .boolean(value.truthy))
            return
        default:
            break
        }
        storeLocal(process, ref, value: coerced)
    }

    private func coerce(_ value: Value, to type: TypeInfo, at location: SourceLocation) throws -> Value {
        switch type {
        case .real:
            if value.isNumeric { return .real(value.asReal) }
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                 location))
        case .integer:
            if case .character(let character) = value {
                return .integer(Int(character.unicodeScalars.first?.value ?? 0))
            }
            if case .boolean(let flag) = value { return .integer(flag ? 1 : 0) }
            if value.isNumeric {
                guard let number = value.asInteger else {
                    throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
                }
                return .integer(number)
            }
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        case .boolean:
            switch value {
            case .boolean: return value
            case .integer, .real: return .boolean(value.truthy)
            default:
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
            }
        case .spinlock:
            switch value {
            case .boolean, .integer: return .boolean(value.truthy)
            default:
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
            }
        case .character:
            if case .character = value { return value }
            if case .string(let string) = value, string.count == 1, let character = string.first {
                return .character(character)
            }
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                 location))
        default:
            return value
        }
    }

    // MARK: - Channels

    /// Takes one packet from a channel, blocking until one arrives.
    func readChannel(_ buffer: ChannelBuffer, ref: MemoryRef, process: Process) throws -> Value {
        if !buffer.queue.isEmpty {
            let value = buffer.queue.removeFirst()
            chargeChannelOperation()
            return value
        }
        process.waitingOn = buffer
        throw Suspend.block(.channelRead(ref), readyAt: nil)
    }

    /// Puts one packet on a channel and wakes a reader waiting for it.
    func sendChannel(_ buffer: ChannelBuffer, value: Value, ref: MemoryRef,
                     target: Expression) {
        buffer.queue.append(value)
        chargeChannelOperation()
        wakeReaders(of: buffer)
        _ = ref
        _ = target
    }

    private func wakeReaders(of buffer: ChannelBuffer) {
        for other in processes where other.state == .blocked && !other.terminated {
            if case .channelRead = other.blockReason, other.waitingOn === buffer {
                makeRunnable(other)
            }
        }
    }

    private func chargeChannelOperation() {
        charge(timing.channelOperation)
        if !program.architecture.topology.isSharedMemory {
            // A packet also crosses the communication link.
            charge(timing.linkDelay)
        }
    }

    // MARK: - Evaluation

    func evaluate(_ expression: Expression, _ process: Process) throws -> Value {
        // A variable reference is a load; a channel-typed reference is a channel read.
        // Constants are values, not addresses, so they must be resolved before the
        // address path (otherwise a runtime expression such as `N` in `1 to N`
        // incorrectly reports "Error in Variable Name").
        switch expression {
        case .identifier(let name, let location):
            let binding = process.frame.scope.lookup(name)
            if case .constant(let value, _)? = binding {
                return value
            }
            // Pascal calls a parameterless function without parentheses: `x := Next;`.
            if binding == nil, let index = program.routine(named: name).first,
               program.routines[index].isFunction {
                return try evaluateCall(name, [], location, process)
            }
            let ref = try address(of: expression, process)
            let type = staticType(of: expression, process)
            if case .channelOf = type {
                guard case .channel(let buffer) = try rawLoad(ref: ref, process: process) else {
                    throw MPWinError.runtime(Diagnostic(.error,
                        "Attempt to read a channel that is not initialised", expression.location))
                }
                return try readChannel(buffer, ref: ref, process: process)
            }
            return try load(ref: ref, type: type, process: process)
        case .index, .fieldAccess, .dereference:
            let ref = try address(of: expression, process)
            let type = staticType(of: expression, process)
            if case .channelOf = type {
                guard case .channel(let buffer) = try rawLoad(ref: ref, process: process) else {
                    throw MPWinError.runtime(Diagnostic(.error,
                        "Attempt to read a channel that is not initialised", expression.location))
                }
                return try readChannel(buffer, ref: ref, process: process)
            }
            return try load(ref: ref, type: type, process: process)
        default:
            break
        }

        switch expression {
        case .integerLiteral(let value, _):
            return .integer(value)
        case .realLiteral(let value, _):
            return .real(value)
        case .stringLiteral(let value, _):
            // Pascal's single-character quoted literal is a CHAR; longer quoted
            // literals are retained as strings so they can be written verbatim.
            if value.count == 1, let character = value.first {
                return .character(character)
            }
            return .string(value)
        case .booleanLiteral(let value, _):
            return .boolean(value)
        case .nilLiteral:
            return .pointer(nil)

        case .unary(let op, let inner, let location):
            return try evaluateUnary(op, inner, location, process)

        case .binary(let op, let lhs, let rhs, let location):
            return try Operations.binary(op, try evaluate(lhs, process),
                                         try evaluate(rhs, process), location)

        case .builtinCall(let builtin, let arguments, let location):
            return try evaluateBuiltin(builtin, arguments, location, process)

        case .call(let name, let arguments, let location):
            return try evaluateCall(name, arguments, location, process)

        case .identifier(let name, let location):
            if case .constant(let value, _)? = process.frame.scope.lookup(name) { return value }
            throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", location))


        default:
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                 expression.location))
        }
    }

    private func evaluateUnary(_ op: String, _ inner: Expression, _ location: SourceLocation,
                               _ process: Process) throws -> Value {
        if op == "chan?" {
            let type = staticType(of: inner, process)
            guard case .channelOf = type else {
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                     location))
            }
            let ref = try address(of: inner, process)
            guard case .channel(let buffer) = try rawLoad(ref: ref, process: process) else {
                throw MPWinError.runtime(Diagnostic(.error,
                    "Attempt to test a channel that is not initialised", location))
            }
            return .boolean(!buffer.queue.isEmpty)
        }
        let value = try evaluate(inner, process)
        switch op {
        case "-":
            switch value {
            case .integer(let number):
                let (result, overflow) = 0.subtractingReportingOverflow(number)
                guard !overflow else {
                    throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
                }
                return .integer(result)
            case .real(let number): return .real(-number)
            default:
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                     location))
            }
        case "not":
            switch value {
            case .boolean(let flag): return .boolean(!flag)
            case .integer(let number): return .integer(~number)
            default:
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                     location))
            }
        default:
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                 location))
        }
    }

    private func evaluateCall(_ name: String, _ arguments: [Argument],
                              _ location: SourceLocation, _ process: Process) throws -> Value {
        guard let index = program.routine(named: name).first else {
            throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", location))
        }
        let depth = process.frames.count
        try performCall(process, index, arguments, returnOffset: 0)
        return try runInline(process, depth: depth)
    }

    /// Runs a called function to completion inside the current statement.
    private func runInline(_ process: Process, depth: Int) throws -> Value {
        var captured = Value.void
        while process.frames.count > depth {
            // The scheduler only checks between statements, and this loop runs a whole
            // function inside one, so an endless loop here must check for itself.
            if isCancelled { throw Interrupt.cancelled }
            let frame = process.frames[process.frames.count - 1]
            let routine = program.routines[frame.routine]
            guard frame.op < routine.code.count else {
                if let slot = routine.resultSlot, let value = frame.slots[slot] {
                    captured = value
                }
                try leaveRoutine(process)
                continue
            }
            let op = routine.code[frame.op]
            do {
                try step(process, op, line: 0)
            } catch let suspend as Suspend {
                // A blocking operation inside a function re-enters it on resume; the
                // functions in the original's sample programs are free of side effects
                // across such a suspension.
                process.resumePending = false
                throw suspend
            }
        }
        return captured
    }

    private func evaluateBuiltin(_ builtin: Builtin, _ arguments: [Expression],
                                 _ location: SourceLocation, _ process: Process) throws -> Value {
        func argument(_ index: Int) throws -> Value {
            guard index < arguments.count else {
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.",
                                                     location))
            }
            return try evaluate(arguments[index], process)
        }
        func checkedInteger(_ number: Double) throws -> Int {
            let rounded = number
            guard rounded.isFinite, rounded >= Double(Int.min), rounded < Double(Int.max) else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return Int(rounded)
        }
        func checkedReal(_ number: Double) throws -> Double {
            guard number.isFinite else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return number
        }
        switch builtin {
        case .selfProcess:
            // MPWin's %SELF denotes the processor executing the current process.
            return .integer(process.processor)
        case .myid:
            // %MYID denotes the simulator process identifier.
            return .integer(process.id)
        case .clock:
            return .real(Double(time))
        case .seqtime:
            return .integer(process.sequentialTime)

        case .abs:
            switch try argument(0) {
            case .integer(let number):
                guard number != Int.min else {
                    throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
                }
                return .integer(abs(number))
            case .real(let number): return .real(abs(number))
            default:
                throw MPWinError.semantic(Diagnostic(.error, "ABS requires an integer or real expression.", location))
            }
        case .sqr:
            switch try argument(0) {
            case .integer(let number):
                let (result, overflow) = number.multipliedReportingOverflow(by: number)
                guard !overflow else {
                    throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
                }
                return .integer(result)
            case .real(let number): return .real(try checkedReal(number * number))
            default:
                throw MPWinError.semantic(Diagnostic(.error, "SQR requires an integer or real expression.", location))
            }
        case .odd:
            guard case .integer(let number) = try argument(0) else {
                throw MPWinError.semantic(Diagnostic(.error, "ODD requires an integer expression.", location))
            }
            return .boolean(number % 2 != 0)
        case .chr:
            guard case .integer(let code) = try argument(0),
                  let scalar = UnicodeScalar(code) else {
                throw MPWinError.semantic(Diagnostic(.error, "CHR requires a valid ordinal integer.", location))
            }
            return .character(Character(scalar))
        case .ord:
            switch try argument(0) {
            case .integer(let number): return .integer(number)
            case .boolean(let flag): return .integer(flag ? 1 : 0)
            case .character(let character):
                return .integer(Int(character.unicodeScalars.first?.value ?? 32))
            case .string(let string) where string.count == 1:
                return .integer(Int(string.unicodeScalars.first?.value ?? 32))
            default:
                throw MPWinError.semantic(Diagnostic(.error, "ORD requires an ordinal expression.", location))
            }
        case .succ, .pred:
            let value = try argument(0)
            let isSuccessor: Bool
            if case .succ = builtin { isSuccessor = true } else { isSuccessor = false }
            switch value {
            case .integer(let number):
                let result = isSuccessor
                    ? number.addingReportingOverflow(1)
                    : number.subtractingReportingOverflow(1)
                guard !result.overflow else {
                    throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
                }
                return .integer(result.partialValue)
            case .character(let character):
                guard let scalar = character.unicodeScalars.first,
                      character.unicodeScalars.count == 1 else {
                    throw MPWinError.runtime(Diagnostic(.error, "Ordinal character is out of range.", location))
                }
                let next: UInt32
                if isSuccessor {
                    guard scalar.value < 0x10FFFF else {
                        throw MPWinError.runtime(Diagnostic(.error, "Ordinal character is out of range.", location))
                    }
                    next = scalar.value + 1
                } else {
                    guard scalar.value > 0 else {
                        throw MPWinError.runtime(Diagnostic(.error, "Ordinal character is out of range.", location))
                    }
                    next = scalar.value - 1
                }
                guard let nextScalar = UnicodeScalar(next) else {
                    throw MPWinError.runtime(Diagnostic(.error, "Ordinal character is out of range.", location))
                }
                return .character(Character(nextScalar))
            case .boolean(let flag):
                if isSuccessor, !flag { return .boolean(true) }
                if !isSuccessor, flag { return .boolean(false) }
                throw MPWinError.runtime(Diagnostic(.error, "Boolean ordinal value is out of range.", location))
            default:
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
            }
        case .round:
            return .integer(try checkedInteger((try argument(0).asReal).rounded()))
        case .trunc:
            return .integer(try checkedInteger((try argument(0).asReal).rounded(.towardZero)))
        case .sin:
            return .real(try checkedReal(sin(try argument(0).asReal)))
        case .cos:
            return .real(try checkedReal(cos(try argument(0).asReal)))
        case .exp:
            return .real(try checkedReal(exp(try argument(0).asReal)))
        case .ln:
            let value = try argument(0).asReal
            guard value > 0 else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return .real(try checkedReal(log(value)))
        case .sqrt:
            let value = try argument(0).asReal
            guard value >= 0 else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return .real(try checkedReal(value.squareRoot()))
        case .arctan:
            return .real(try checkedReal(atan(try argument(0).asReal)))
        case .eof:
            return .boolean(atEndOfInput)
        case .eoln:
            return .boolean(atEndOfLine)
        }
    }
}
