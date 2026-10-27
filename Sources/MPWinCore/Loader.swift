// Created by Amirali Yazdani on 10/16/26.
import Foundation

/// Flattens a parsed `CompiledUnit` into per-routine op arrays with resolved scopes,
/// types, global addresses and jump targets.
public struct Loader {
    /// Safety cap for a single program's simulated memory. This prevents malformed
    /// source from trying to allocate billions of host-side Value cells at compile time.
    private static let maximumMemoryWords = 1_000_000

    private let unit: CompiledUnit
    private var typeAliases: [String: TypeInfo] = [:]
    private var constants: [String: Binding] = [:]
    private var nextAddress = 0
    private var globalSegment: [Segment] = []
    private var executableLines: Set<Int> = []
    /// Main program is routine 0; declared routines follow at 1...n.
    private var routineIndexByName: [String: [Int]] = [:]

    public init(unit: CompiledUnit) {
        self.unit = unit
    }

    public static func load(_ unit: CompiledUnit) throws -> CompiledProgram {
        var loader = Loader(unit: unit)
        return try loader.build()
    }

    // MARK: - Build

    private mutating func build() throws -> CompiledProgram {
        // 1. Constants are populated before resolving named types because array
        // bounds and other type expressions may legally refer to earlier constants.
        // Values only need literal/previous-constant evaluation at this stage;
        // explicit constant type annotations are resolved once aliases are available.
        for declaration in unit.constants {
            let value = try constantValue(declaration.value)
            constants[declaration.name.lowercased()] = .constant(value, typeOfLiteral(value))
        }

        // 2. Named types, so aliases may reference constants used in their bounds.
        for declaration in unit.types {
            typeAliases[declaration.name.lowercased()] = try resolve(declaration.type)
        }

        // Resolve any explicit constant type annotations now that named types exist.
        for declaration in unit.constants {
            guard let binding = constants[declaration.name.lowercased()] else { continue }
            let value: Value
            switch binding {
            case .constant(let v, _): value = v
            default: continue
            }
            let type = try declaration.type.map { try resolve($0) } ?? typeOfLiteral(value)
            constants[declaration.name.lowercased()] = .constant(value, type)
        }

        // 3. Globals occupy contiguous shared addresses.
        var globalTable: [String: Binding] = constants
        for declaration in unit.globals {
            let type = try resolve(declaration.type)
            let footprint = max(1, type.footprint)
            for name in declaration.names {
                guard footprint <= Self.maximumMemoryWords - nextAddress else {
                    throw MPWinError.semantic(Diagnostic(.error,
                        "Storage overflow: program memory exceeds the supported limit of 1,000,000 words.",
                        .unknown))
                }
                let ref = MemoryRef(segment: .shared, address: nextAddress)
                globalTable[name.lowercased()] = .global(ref, type)
                for _ in 0..<footprint {
                    globalSegment.append(.shared)
                    nextAddress += 1
                }
            }
        }
        let globalScope = Scope(table: globalTable, parent: nil)

        // 4. Routine name index, using final (post-main-insertion) indices.
        for (offset, routine) in unit.routines.enumerated() {
            routineIndexByName[routine.name.lowercased(), default: []].append(offset + 1)
        }

        // 5. Compile declared routines, then prepend the main program.
        var compiled: [CompiledRoutine] = []
        for routine in unit.routines {
            compiled.append(try compileRoutine(routine, parent: globalScope))
        }
        let mainRoutine = try compileMain(globalScope: globalScope)

        // Derive breakpointable lines from the final compiled source maps.
        // StatementCompiler modifies a value-copy of Loader, so its
        // executable-line annotations do not propagate back to this instance.
        let allRoutines = [mainRoutine] + compiled
        executableLines = Set(allRoutines.flatMap(\.lines).filter { $0 > 0 })

        let architecture = try unit.architecture.map { spec in
            let total = spec.topology.processorCount(parameter: spec.parameter)
            guard spec.parameter > 0 else {
                throw MPWinError.semantic(Diagnostic(.error,
                    "Multicomputer architecture parameters must be positive integer values",
                    spec.location))
            }
            guard total <= 512 else {
                throw MPWinError.semantic(Diagnostic(.error,
                    "Multicomputer architecture parameters must be positive integer values",
                    spec.location))
            }
            return spec
        } ?? ArchitectureSpec(topology: .shared, parameter: 512, location: .unknown)

        return CompiledProgram(
            name: unit.programName,
            architecture: architecture,
            routines: allRoutines,
            mainRoutine: 0,
            globalScope: globalScope,
            globalFootprint: nextAddress,
            globalSegment: globalSegment,
            sourceLines: unit.sourceLines,
            executableLines: executableLines
        )
    }

    // MARK: - Types

    private mutating func resolve(_ node: TypeNode) throws -> TypeInfo {
        switch node {
        case .integer: return .integer
        case .real: return .real
        case .boolean: return .boolean
        case .char: return .character
        case .spinlock: return .spinlock
        case .channelOf(let element, _):
            return .channelOf(try resolve(element))
        case .pointer(let target, _):
            return .pointer(try resolve(target))
        case .named(let name, let location):
            if let alias = typeAliases[name.lowercased()] { return alias }
            throw MPWinError.semantic(Diagnostic(.error,
                "The identifier must be a \"Type Identifier\".", location))
        case .array(let lowers, let uppers, let elementNode, let location):
            let element = try resolve(elementNode)
            guard lowers.count == uppers.count, !lowers.isEmpty else {
                throw MPWinError.semantic(Diagnostic(.error,
                    "The bounds of the index in the array definition exhibits one of the following errors: lower exveeds upper bound, types of bounds do not much, type is real, index range exceedsthe limit 32767.",
                    location))
            }
            var lowerBounds: [Int] = []
            var upperBounds: [Int] = []
            for (lower, upper) in zip(lowers, uppers) {
                let upperValue = try constantInteger(upper, location)
                let lowerValue = try lower.map { try constantInteger($0, location) } ?? -32768
                guard upperValue >= lowerValue,
                      upperValue >= -32767 && upperValue <= 32767,
                      lowerValue >= -32767 && lowerValue <= 32767 else {
                    throw MPWinError.semantic(Diagnostic(.error,
                        "The bounds of the index in the array definition exhibits one of the following errors: lower exveeds upper bound, types of bounds do not much, type is real, index range exceedsthe limit 32767.",
                        location))
                }
                lowerBounds.append(lowerValue)
                upperBounds.append(upperValue)
            }
            var footprint = max(1, element.footprint)
            for (low, high) in zip(lowerBounds, upperBounds) {
                let extent = high - low + 1
                let (next, overflow) = footprint.multipliedReportingOverflow(by: extent)
                guard !overflow && next <= Self.maximumMemoryWords else {
                    throw MPWinError.semantic(Diagnostic(.error,
                        "Storage overflow: array type exceeds the supported limit of 1,000,000 words.",
                        location))
                }
                footprint = next
            }
            return .array(element: element, lower: lowerBounds, upper: upperBounds)
        case .record(let fields, let location):
            var resolved: [RecordField] = []
            var offset = 0
            for field in fields {
                let type = try resolve(field.type)
                for name in field.names {
                    let footprint = max(1, type.footprint)
                    guard footprint <= Self.maximumMemoryWords - offset else {
                        throw MPWinError.semantic(Diagnostic(.error,
                            "Storage overflow: record type exceeds the supported limit of 1,000,000 words.",
                            location))
                    }
                    resolved.append(RecordField(name: name, offset: offset, type: type))
                    offset += footprint
                }
            }
            guard !resolved.isEmpty else {
                throw MPWinError.semantic(Diagnostic(.error, "Record Has Too Many Components", location))
            }
            return .record(resolved)
        }
    }

    private func constantInteger(_ expression: Expression, _ location: SourceLocation) throws -> Int {
        let value = try constantValue(expression)
        switch value {
        case .integer(let result): return result
        case .boolean(let flag): return flag ? 1 : 0
        default:
            throw MPWinError.semantic(Diagnostic(.error,
                "The bounds of the index in the array definition exhibits one of the following errors: lower exveeds upper bound, types of bounds do not much, type is real, index range exceedsthe limit 32767.",
                location))
        }
    }

    private func constantValue(_ expression: Expression) throws -> Value {
        switch expression {
        case .integerLiteral(let value, _):
            return .integer(value)
        case .realLiteral(let value, _):
            return .real(value)
        case .stringLiteral(let value, _):
            if value.count == 1, let character = value.first {
                return .character(character)
            }
            // Multi-character/empty literals are retained for output constants;
            // they are not a general mutable STRING type in the recovered dialect.
            return .string(value)
        case .booleanLiteral(let value, _):
            return .boolean(value)
        case .nilLiteral:
            return .void
        case .identifier(let name, let location):
            if case .constant(let value, _)? = constants[name.lowercased()] { return value }
            throw MPWinError.semantic(Diagnostic(.error,
                "Constants must be defined by a literal or a previously defined constant identifier.",
                location))
        case .unary("-", let inner, let location):
            switch try constantValue(inner) {
            case .integer(let value): return .integer(-value)
            case .real(let value): return .real(-value)
            default:
                throw MPWinError.semantic(Diagnostic(.error,
                    "Error in the indicated expression.", location))
            }
        case .unary("+", let inner, _):
            return try constantValue(inner)
        case .unary("not", let inner, let location):
            switch try constantValue(inner) {
            case .boolean(let value): return .boolean(!value)
            case .integer(let value): return .integer(~value)
            default:
                throw MPWinError.semantic(Diagnostic(.error,
                    "Error in the indicated expression.", location))
            }
        case .binary(let op, let lhs, let rhs, let location):
            let left = try constantValue(lhs)
            let right = try constantValue(rhs)
            return try Operations.binary(op, left, right, location)
        case .builtinCall(.abs, let args, let location):
            guard args.count == 1, case .integer(let value) = try constantValue(args[0]) else {
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
            }
            guard value != Int.min else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return .integer(abs(value))
        default:
            throw MPWinError.semantic(Diagnostic(.error,
                "Constants must be defined by a literal or a previously defined constant identifier.",
                expression.location))
        }
    }

    private func typeOfLiteral(_ value: Value) -> TypeInfo {
        switch value {
        case .integer: return .integer
        case .real: return .real
        case .boolean: return .boolean
        case .character: return .character
        default: return .integer
        }
    }

    // MARK: - Routine compilation

    private mutating func compileRoutine(_ routine: RoutineDecl, parent: Scope) throws -> CompiledRoutine {
        var table: [String: Binding] = [:]
        var slot = 0
        var valueParams = 0
        var varParams = 0
        var resultSlot: Int?
        var resultType: TypeInfo = .integer
        var parameters: [RoutineParameter] = []

        for param in routine.params {
            let type = try resolve(param.type)
            let binding: Binding
            if param.isVar {
                binding = .varParam(varParams, type)
                varParams += 1
            } else {
                binding = .localSlot(slot, type)
                slot += max(1, type.footprint)
                valueParams += 1
            }
            table[param.name.lowercased()] = binding
            parameters.append(RoutineParameter(name: param.name, binding: binding))
        }
        for local in routine.locals {
            let type = try resolve(local.type)
            for name in local.names {
                table[name.lowercased()] = .localSlot(slot, type)
                slot += max(1, type.footprint)
            }
        }
        if routine.isFunction {
            resultType = try routine.resultType.map { try resolve($0) } ?? typeOfLiteral(.integer(0))
            resultSlot = slot
            table[routine.name.lowercased()] = .functionResult(slot, resultType)
            slot += max(1, resultType.footprint)
        }

        guard slot >= 0 && slot <= Self.maximumMemoryWords else {
            throw MPWinError.semantic(Diagnostic(.error,
                "Storage overflow: routine frame exceeds the supported limit of 1,000,000 words.",
                routine.location))
        }
        let scope = Scope(table: table, parent: parent)
        var compiler = StatementCompiler(
            loader: self,
            scope: scope,
            slotCount: slot,
            functionResultType: resultType
        )
        try compiler.compile(routine.body ?? [])

        return CompiledRoutine(
            name: routine.name,
            isFunction: routine.isFunction,
            resultType: resultType,
            code: compiler.code,
            lines: compiler.lines,
            scope: scope,
            localCount: compiler.slotCount,
            paramCount: valueParams,
            parameters: parameters,
            resultSlot: resultSlot,
            location: routine.location
        )
    }

    private mutating func compileMain(globalScope: Scope) throws -> CompiledRoutine {
        var compiler = StatementCompiler(loader: self, scope: globalScope, slotCount: 0,
                                         functionResultType: .integer)
        try compiler.compile(unit.body)
        return CompiledRoutine(
            name: unit.programName,
            isFunction: false,
            resultType: .integer,
            code: compiler.code,
            lines: compiler.lines,
            scope: globalScope,
            localCount: compiler.slotCount,
            paramCount: 0,
            parameters: [],
            resultSlot: nil,
            location: .unknown
        )
    }

    // MARK: - Services for StatementCompiler

    fileprivate mutating func typeInfo(for node: TypeNode) throws -> TypeInfo {
        try resolve(node)
    }

    fileprivate func routineIndex(named name: String) -> Int? {
        routineIndexByName[name.lowercased()]?.first
    }

    fileprivate mutating func noteExecutable(line: Int) {
        if line > 0 { executableLines.insert(line) }
    }

    fileprivate mutating func noteExecutable(line: SourceLocation) {
        noteExecutable(line: line.line)
    }
}

// MARK: - Statement compiler

/// Emits a flat op array for one routine, resolving scopes and back-patching jumps.
struct StatementCompiler {
    var loader: Loader
    var scope: Scope
    var slotCount: Int
    var functionResultType: TypeInfo
    /// Non-zero while compiling a spawned FORALL body. Nested FOR loops must use
    /// private loop slots instead of accidentally sharing a global loop variable.
    var parallelDepth: Int = 0
    var code: [Op] = []
    var lines: [Int] = []

    // MARK: Emission

    @discardableResult
    private mutating func emit(_ op: Op, _ line: Int) -> Int {
        code.append(op)
        lines.append(line)
        return code.count - 1
    }

    @discardableResult
    private mutating func emit(_ op: Op, _ location: SourceLocation) -> Int {
        emit(op, location.line)
    }

    /// Reserves an op index so a spawned body can be compiled at fixed offsets.
    private mutating func reserve(_ location: SourceLocation) -> Int {
        emit(.noop, location)
    }

    private mutating func patchJump(_ index: Int, to target: Int) {
        if case .jump = code[index] { code[index] = .jump(target) }
    }

    private mutating func patchJumpIfFalse(_ index: Int, to target: Int) {
        if case .jumpIfFalse(let condition, _) = code[index] {
            code[index] = .jumpIfFalse(condition, target)
        }
    }

    // MARK: Entry

    mutating func compile(_ statements: [Statement]) throws {
        try compileBlock(statements, scope: scope)
    }

    /// Compiles a statement list, honouring a leading `Var ... begin` declaration block.
    private mutating func compileBlock(_ statements: [Statement], scope blockScope: Scope) throws {
        var rest = statements[statements.startIndex...]
        if case .declarationBlock(let decls, _) = rest.first {
            var table: [String: Binding] = [:]
            var slots: [(String, TypeInfo)] = []
            for decl in decls {
                let type = try loader.typeInfo(for: decl.type)
                for name in decl.names {
                    table[name.lowercased()] = .localSlot(slotCount, type)
                    slots.append((name, type))
                    slotCount += 1
                }
            }
            let inner = Scope(table: table, parent: blockScope)
            emit(.declareBlock(inner, slots), 0)
            rest = rest.dropFirst()
            try compileBlock(Array(rest), scope: inner)
            emit(.leaveBlock, 0)
            return
        }
        for statement in rest {
            try compile(statement, scope: blockScope)
        }
    }

    // MARK: Statements

    private mutating func compile(_ statement: Statement, scope blockScope: Scope) throws {
        switch statement {
        case .empty:
            break

        case .declarationBlock:
            throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", statement.location))

        case .compound(let list, _):
            try compileBlock(list, scope: blockScope)

        case .assignment(let target, let value, let line):
            loader.noteExecutable(line: line)
            emit(.assign(target, value), line)

        case .procedureCall(let callee, let line):
            try compileCall(callee, location: line)

        case .if(let condition, let thenBranch, let elseBranch, let line):
            loader.noteExecutable(line: line)
            let skipElse = emit(.jumpIfFalse(condition, 0), line)
            try compile(thenBranch, scope: blockScope)
            if let elseBranch {
                let skipEnd = emit(.jump(0), line)
                patchJumpIfFalse(skipElse, to: code.count)
                try compile(elseBranch, scope: blockScope)
                patchJump(skipEnd, to: code.count)
            } else {
                patchJumpIfFalse(skipElse, to: code.count)
            }

        case .while(let condition, let body, let line):
            loader.noteExecutable(line: line)
            let top = code.count
            let exitJump = emit(.jumpIfFalse(condition, 0), line)
            try compile(body, scope: blockScope)
            emit(.jump(top), line)
            patchJumpIfFalse(exitJump, to: code.count)

        case .repeat(let body, let condition, let line):
            loader.noteExecutable(line: line)
            let top = code.count
            try compileBlock(body, scope: blockScope)
            emit(.jumpIfFalse(condition, top), line)

        case .for(let variable, let initial, let final, let ascending, let body, let line):
            try compileFor(variable, initial, final, ascending, body, line: line, scope: blockScope)

        case .case(let subject, let branches, let line):
            loader.noteExecutable(line: line)
            var exits: [Int] = []
            for (label, branchBody) in branches {
                var skip: Int?
                if let label {
                    skip = emit(.jumpIfFalse(.binary("=", subject, label, line), 0), line)
                }
                try compileBlock(branchBody, scope: blockScope)
                exits.append(emit(.jump(0), line))
                if let skip { patchJumpIfFalse(skip, to: code.count) }
            }
            for exit in exits { patchJump(exit, to: code.count) }

        case .with(_, _, let line):
            // Never compile a WITH statement as though its record namespace were
            // applied when that semantic feature has not been implemented.
            throw MPWinError.semantic(Diagnostic(.error,
                "WITH statements are not supported: record-field namespace resolution is not implemented.",
                line))

        case .forall(let header, let body, let line):
            loader.noteExecutable(line: line)
            try compileSpawn(header: header, body: body, line: line, scope: blockScope)

        case .fork(let spawn, let line):
            loader.noteExecutable(line: line)
            try compileFork(spawn, processor: spawn.processor, line: line, scope: blockScope)

        case .allocate(let processor, let spawn, let line):
            loader.noteExecutable(line: line)
            try compileFork(spawn, processor: processor, line: line, scope: blockScope)

        case .port(let ports, let body, let line):
            loader.noteExecutable(line: line)
            try compileFork(ProcessSpawn(ports: ports, body: body), processor: nil, line: line,
                            scope: blockScope)

        case .join(let line):
            loader.noteExecutable(line: line)
            emit(.join, line)

        case .duration(let value, let line):
            loader.noteExecutable(line: line)
            emit(.duration(value), line)

        case .lock(let target, let line):
            loader.noteExecutable(line: line)
            emit(.lock(target), line)

        case .unlock(let target, let line):
            loader.noteExecutable(line: line)
            emit(.unlock(target), line)

        case .seqoff(let line):
            loader.noteExecutable(line: line)
            emit(.seqoff, line)

        case .seqon(let line):
            loader.noteExecutable(line: line)
            emit(.seqon, line)

        case .read(let targets, let newline, let line):
            loader.noteExecutable(line: line)
            emit(.read(targets, newline), line)

        case .write(let items, let newline, let line):
            loader.noteExecutable(line: line)
            emit(.write(items, newline), line)

        case .pointerNew(let target, let line):
            loader.noteExecutable(line: line)
            emit(.newPointer(target), line)

        case .pointerDispose(let target, let line):
            loader.noteExecutable(line: line)
            emit(.dispose(target), line)

        case .halt(let line):
            loader.noteExecutable(line: line)
            emit(.noop, line)
        }
    }

    // MARK: Loops

    private func bindingType(_ binding: Binding) -> TypeInfo {
        switch binding {
        case .global(_, let type), .constant(_, let type), .localSlot(_, let type),
             .varParam(_, let type), .typeAlias(let type), .functionResult(_, let type),
             .loopIndex(_, let type):
            return type
        }
    }

    private mutating func compileFor(_ variable: String, _ initial: Expression, _ final: Expression,
                                     _ ascending: Bool, _ body: Statement, line: SourceLocation,
                                     scope blockScope: Scope) throws {
        loader.noteExecutable(line: line.line)
        // The loop variable keeps the binding it already has, so Pascal's semantics
        // (a shared variable is modified) are preserved.
        var table: [String: Binding] = [:]
        let privateLoop = parallelDepth > 0
        guard let existing = blockScope.lookup(variable) else {
            throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", line))
        }
        let loopType = bindingType(existing)
        guard loopType == .integer || loopType == .character || loopType == .boolean else {
            throw MPWinError.semantic(Diagnostic(.error,
                "A FOR loop variable must have an ordinal type (INTEGER, CHAR, or BOOLEAN).", line))
        }
        switch existing {
        case .global, .localSlot, .varParam, .functionResult, .loopIndex:
            break
        case .constant, .typeAlias:
            throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", line))
        }
        if !privateLoop {
            table[variable.lowercased()] = existing
        } else {
            // A nested FOR loop has a private index to avoid mutating a shared
            // variable from several simulated processes, but it retains the
            // declared ordinal type (CHAR/BOOLEAN as well as INTEGER).
            table[variable.lowercased()] = .loopIndex(slotCount, loopType)
            slotCount += 1
        }
        let limitSlot = slotCount
        slotCount += 1
        table["__mp_limit"] = .localSlot(limitSlot, loopType)
        let loopScope = Scope(table: table, parent: blockScope)

        emit(.enterScope(loopScope), line)
        emit(.assign(.identifier(variable, line), initial), line)
        emit(.assign(.identifier("__mp_limit", line), final), line)

        let top = code.count
        let reference = Expression.identifier(variable, line)
        let limit = Expression.identifier("__mp_limit", line)
        let continueWhile: Expression = ascending
            ? .binary("<=", reference, limit, line)
            : .binary(">=", reference, limit, line)
        let exitJump = emit(.jumpIfFalse(continueWhile, 0), line)
        try compile(body, scope: loopScope)

        // Do not increment once more after the terminal value. Apart from
        // matching Pascal FOR semantics, this avoids overflow at Int.max and
        // avoids asking SUCC(TRUE) or SUCC('…') beyond the selected range.
        let hasNext: Expression = ascending
            ? .binary("<", reference, limit, line)
            : .binary(">", reference, limit, line)
        let finishJump = emit(.jumpIfFalse(hasNext, 0), line)
        let step: Expression = .builtinCall(ascending ? .succ : .pred, [reference], line)
        emit(.assign(reference, step), line)
        emit(.jump(top), line)
        let finish = code.count
        patchJumpIfFalse(exitJump, to: finish)
        patchJumpIfFalse(finishJump, to: finish)
        emit(.leaveScope, line)
    }

    // MARK: Calls

    private mutating func compileCall(_ callee: Expression, location: SourceLocation) throws {
        guard case .call(let name, let args, _) = callee else {
            throw MPWinError.semantic(Diagnostic(.error,
                "Only a procedure call may appear as a standalone statement.", location))
        }
        guard let index = loader.routineIndex(named: name) else {
            throw MPWinError.semantic(Diagnostic(.error, "Error in Variable Name", location))
        }
        loader.noteExecutable(line: location.line)
        emit(.call(index, args, name), location.line)
    }

    // MARK: Process spawning

    private mutating func compileSpawn(header: ForallHeader, body: Statement, line: SourceLocation,
                                       scope blockScope: Scope) throws {
        var processor: Expression?
        var ports: [Expression] = []
        var effectiveBody = body

        // Peel any combination of (@processor) and Port prefixes. This lets the parser
        // preserve forms such as `(@3 Port ch) statement` without losing either modifier.
        while true {
            switch effectiveBody {
            case .allocate(let proc, let spawn, _):
                processor = proc
                ports.append(contentsOf: spawn.ports)
                effectiveBody = spawn.body
            case .port(let list, let inner, _):
                ports.append(contentsOf: list)
                effectiveBody = inner
            default:
                break
            }
            switch effectiveBody {
            case .allocate, .port:
                continue
            default:
                break
            }
            break
        }

        let indexSlot = slotCount
        slotCount += 1
        let bodyScope = Scope(
            table: [header.indexVariable.lowercased(): .loopIndex(indexSlot, .integer)],
            parent: blockScope
        )

        // Reserve the FORALL op, then put a parent-only jump before the inline child body.
        // The spawned process starts at `bodyStart`; the parent advances into the jump.
        let spawnIndex = reserve(line)
        let skipBody = emit(.jump(0), line)
        let bodyStart = code.count
        let savedParallelDepth = parallelDepth
        parallelDepth += 1
        defer { parallelDepth = savedParallelDepth }
        try compile(effectiveBody, scope: bodyScope)
        let bodyEnd = code.count
        emit(.spawnEnd, line)
        patchJump(skipBody, to: code.count)

        code[spawnIndex] = .forall(ForallOp(
            indexVariable: header.indexVariable,
            initial: header.initial,
            final: header.final,
            grouping: header.grouping,
            processor: processor,
            ports: ports,
            bodyScope: bodyScope,
            indexSlot: indexSlot,
            bodyStart: bodyStart,
            bodyEnd: bodyEnd
        ))
    }

    private mutating func compileFork(_ spawn: ProcessSpawn, processor: Expression?,
                                      line: SourceLocation, scope blockScope: Scope) throws {
        let spawnIndex = reserve(line)
        let skipBody = emit(.jump(0), line)
        let bodyStart = code.count
        try compile(spawn.body, scope: blockScope)
        emit(.spawnEnd, line)
        patchJump(skipBody, to: code.count)
        code[spawnIndex] = .fork(ForkOp(
            processor: processor,
            ports: spawn.ports,
            bodyScope: blockScope,
            bodyStart: bodyStart,
            bodyEnd: code.count - 1
        ))
    }
}
