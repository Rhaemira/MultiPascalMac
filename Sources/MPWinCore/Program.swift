// Created by Amirali Yazdani on 10/16/26.
import Foundation

// MARK: - Bindings

public enum Binding: Sendable {
    case global(MemoryRef, TypeInfo)
    case constant(Value, TypeInfo)
    case localSlot(Int, TypeInfo)
    case varParam(Int, TypeInfo)
    case typeAlias(TypeInfo)
    /// A function name used as an assignment target, i.e. `Aggregate := globaldone`.
    case functionResult(Int, TypeInfo)
    /// A read-only loop index introduced by `FOR`/`FORALL`/`REPEAT`-style bindings.
    case loopIndex(Int, TypeInfo)
}

/// Lexical scope. Block scopes chain to the enclosing block, then the routine, then globals.
/// Scopes are built by the loader and never mutated afterwards, so sharing them between
/// op arrays and the machine is safe.
public final class Scope: @unchecked Sendable {
    public let table: [String: Binding]
    public let parent: Scope?

    public init(table: [String: Binding], parent: Scope?) {
        self.table = table
        self.parent = parent
    }

    public func lookup(_ name: String) -> Binding? {
        var scope: Scope? = self
        while let current = scope {
            if let binding = current.table[name.lowercased()] { return binding }
            scope = current.parent
        }
        return nil
    }
}

// MARK: - Operations

public struct ForallOp: Sendable {
    public var indexVariable: String
    public var initial: Expression
    public var final: Expression
    public var grouping: Expression?
    public var processor: Expression?
    public var ports: [Expression]
    /// Scope for the child body: enclosing scope plus the read-only index binding.
    public var bodyScope: Scope
    /// Slot (in the child's own frame) that receives the index value.
    public var indexSlot: Int
    public var bodyStart: Int
    public var bodyEnd: Int
}

public struct ForkOp: Sendable {
    public var processor: Expression?
    public var ports: [Expression]
    public var bodyScope: Scope
    public var bodyStart: Int
    public var bodyEnd: Int
}

public indirect enum Op: Sendable {
    case noop
    /// `Var ... begin ... end` entry: allocate slots and push the block scope.
    case declareBlock(Scope, [(String, TypeInfo)])
    case enterScope(Scope)
    case leaveScope
    case leaveBlock
    case assign(Expression, Expression)
    case call(Int, [Argument], String)
    case jump(Int)
    case jumpIfFalse(Expression, Int)
    case forall(ForallOp)
    case fork(ForkOp)
    /// End of a spawned body: terminates the child process.
    case spawnEnd
    case join
    case duration(Expression)
    case lock(Expression)
    case unlock(Expression)
    case seqoff
    case seqon
    case read([Expression], Bool)
    case write([WriteItem], Bool)
    case newPointer(Expression)
    case dispose(Expression)
}

// MARK: - Compiled routines

/// A parameter in declaration order, so calls can be bound positionally.
public struct RoutineParameter: Sendable {
    public let name: String
    public let binding: Binding
    public init(name: String, binding: Binding) {
        self.name = name
        self.binding = binding
    }
}

public final class CompiledRoutine: @unchecked Sendable {
    public let name: String
    public let isFunction: Bool
    public let resultType: TypeInfo
    public let code: [Op]
    /// Source line for each op, used by breakpoints, trace and process status.
    public let lines: [Int]
    public let scope: Scope
    public let localCount: Int
    public let paramCount: Int
    /// Parameters in declaration order.
    public let parameters: [RoutineParameter]
    /// Slot holding the function result, when this routine is a function.
    public let resultSlot: Int?
    public let location: SourceLocation

    init(name: String, isFunction: Bool, resultType: TypeInfo, code: [Op], lines: [Int],
         scope: Scope, localCount: Int, paramCount: Int, parameters: [RoutineParameter],
         resultSlot: Int?, location: SourceLocation) {
        self.name = name
        self.isFunction = isFunction
        self.resultType = resultType
        self.code = code
        self.lines = lines
        self.scope = scope
        self.localCount = localCount
        self.paramCount = paramCount
        self.parameters = parameters
        self.resultSlot = resultSlot
        self.location = location
    }
}

// MARK: - Compiled program

public final class CompiledProgram: @unchecked Sendable {
    public let name: String
    public let architecture: ArchitectureSpec
    public let routines: [CompiledRoutine]
    public let mainRoutine: Int
    public let globalScope: Scope
    public let globalFootprint: Int
    /// Home segment per global address, used for data partitioning in multicomputer runs.
    public let globalSegment: [Segment]
    public let sourceLines: Int
    /// Opcode indices per source line, for "executable line" breakpoint validation.
    public let executableLines: Set<Int>

    /// Whether any compiled routine contains a READ/READLN operation.
    public var requiresInput: Bool {
        routines.contains { routine in
            routine.code.contains { op in
                if case .read = op { return true }
                return false
            }
        }
    }

    init(name: String, architecture: ArchitectureSpec, routines: [CompiledRoutine],
         mainRoutine: Int, globalScope: Scope, globalFootprint: Int,
         globalSegment: [Segment], sourceLines: Int, executableLines: Set<Int>) {
        self.name = name
        self.architecture = architecture
        self.routines = routines
        self.mainRoutine = mainRoutine
        self.globalScope = globalScope
        self.globalFootprint = globalFootprint
        self.globalSegment = globalSegment
        self.sourceLines = sourceLines
        self.executableLines = executableLines
    }

    public func routine(named name: String) -> [Int] {
        let target = name.lowercased()
        return routines.indices.filter { routines[$0].name.lowercased() == target }
    }
}
