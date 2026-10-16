// Created by Amirali Yazdani on 10/16/26.
import Foundation

// MARK: - Types

public indirect enum TypeNode: Sendable {
    case named(String, SourceLocation)
    case integer(SourceLocation)
    case real(SourceLocation)
    case boolean(SourceLocation)
    case char(SourceLocation)
    case channelOf(TypeNode, SourceLocation)
    case spinlock(SourceLocation)
    /// `array [e1..e2, e3..e4] of T`; a `nil` lower bound means the minimum integer.
    case array(lower: [Expression?], upper: [Expression], element: TypeNode, SourceLocation)
    case record([FieldDecl], SourceLocation)
    case pointer(TypeNode, SourceLocation)
}

public struct FieldDecl: Sendable {
    public var names: [String]
    public var type: TypeNode
    public init(names: [String], type: TypeNode) {
        self.names = names
        self.type = type
    }
}

public struct ConstDecl: Sendable {
    public var name: String
    public var type: TypeNode?
    public var value: Expression
    public init(name: String, type: TypeNode?, value: Expression) {
        self.name = name
        self.type = type
        self.value = value
    }
}

public struct ParamDecl: Sendable {
    public var name: String
    public var type: TypeNode
    public var isVar: Bool
    /// Set for channels, which the original only allows as `var` parameters.
    public var isChannel: Bool
    public init(name: String, type: TypeNode, isVar: Bool) {
        self.name = name
        self.type = type
        self.isVar = isVar
        self.isChannel = Self.containsChannel(type)
    }
    static func containsChannel(_ type: TypeNode) -> Bool {
        switch type {
        case .channelOf: return true
        case .array(_, _, let element, _): return containsChannel(element)
        case .pointer(let target, _): return containsChannel(target)
        case .record(let fields, _): return fields.contains { containsChannel($0.type) }
        default: return false
        }
    }
}

public struct RoutineDecl: Sendable {
    public var name: String
    public var isFunction: Bool
    public var params: [ParamDecl]
    public var locals: [VarDecl]
    public var body: [Statement]?
    /// Explicit result type of a function, taken from the trailing `: T`.
    public var resultType: TypeNode?
    public var location: SourceLocation
    public var isNested: Bool
    public init(name: String, isFunction: Bool, params: [ParamDecl], locals: [VarDecl],
                body: [Statement]?, resultType: TypeNode?, location: SourceLocation, isNested: Bool) {
        self.name = name
        self.isFunction = isFunction
        self.params = params
        self.locals = locals
        self.body = body
        self.resultType = resultType
        self.location = location
        self.isNested = isNested
    }
}

public struct VarDecl: Sendable {
    public var names: [String]
    public var type: TypeNode
    public init(names: [String], type: TypeNode) {
        self.names = names
        self.type = type
    }
}

public struct TypeDecl: Sendable {
    public var name: String
    public var type: TypeNode
    public init(name: String, type: TypeNode) {
        self.name = name
        self.type = type
    }
}

// MARK: - Expressions

public indirect enum Expression: Sendable {
    case integerLiteral(Int, SourceLocation)
    case realLiteral(Double, SourceLocation)
    case stringLiteral(String, SourceLocation)
    case booleanLiteral(Bool, SourceLocation)
    case nilLiteral(SourceLocation)
    case identifier(String, SourceLocation)
    case unary(String, Expression, SourceLocation)
    case binary(String, Expression, Expression, SourceLocation)
    case fieldAccess(Expression, String, SourceLocation)
    case index(Expression, [Expression], SourceLocation)
    case dereference(Expression, SourceLocation)
    case builtinCall(Builtin, [Expression], SourceLocation)
    case call(String, [Argument], SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .integerLiteral(_, let l), .realLiteral(_, let l), .stringLiteral(_, let l),
             .booleanLiteral(_, let l), .nilLiteral(let l), .identifier(_, let l),
             .unary(_, _, let l), .binary(_, _, _, let l), .fieldAccess(_, _, let l),
             .index(_, _, let l), .dereference(_, let l), .builtinCall(_, _, let l),
             .call(_, _, let l):
            return l
        }
    }

    /// The leading identifier, used for variable-vs-call disambiguation.
    public var leadingName: String? {
        switch self {
        case .identifier(let name, _): return name
        case .call(let name, _, _): return name
        default: return nil
        }
    }
}

public enum Builtin: Sendable {
    case abs, sqr, odd, chr, ord, succ, pred, round, trunc
    case sin, cos, exp, ln, sqrt, arctan, eof, eoln
    case selfProcess, myid, clock, seqtime
}

public struct Argument: Sendable {
    public var isVar: Bool
    public var value: Expression
    public init(isVar: Bool, value: Expression) {
        self.isVar = isVar
        self.value = value
    }
}

// MARK: - Statements

public struct WriteItem: Sendable {
    public var value: Expression
    public var width: Expression?
    public var decimals: Expression?
    public init(value: Expression, width: Expression?, decimals: Expression?) {
        self.value = value
        self.width = width
        self.decimals = decimals
    }
}

public indirect enum Statement: Sendable {
    case empty(SourceLocation)
    case compound([Statement], SourceLocation)
    /// `Var ... begin ... end` — a statement block with its own local declarations.
    case declarationBlock([VarDecl], SourceLocation)
    case assignment(Expression, Expression, SourceLocation)
    case procedureCall(Expression, SourceLocation)
    case `if`(Expression, Statement, Statement?, SourceLocation)
    case `while`(Expression, Statement, SourceLocation)
    case `repeat`([Statement], Expression, SourceLocation)
    case `for`(String, Expression, Expression, Bool, Statement, SourceLocation)
    case `case`(Expression, [(Expression?, [Statement])], SourceLocation)
    case with(Expression, Statement, SourceLocation)
    case forall(ForallHeader, Statement, SourceLocation)
    case fork(ProcessSpawn, SourceLocation)
    case join(SourceLocation)
    case port([Expression], Statement, SourceLocation)
    case allocate(Expression, ProcessSpawn, SourceLocation)
    case duration(Expression, SourceLocation)
    case lock(Expression, SourceLocation)
    case unlock(Expression, SourceLocation)
    case seqoff(SourceLocation)
    case seqon(SourceLocation)
    case read([Expression], Bool, SourceLocation)
    case write([WriteItem], Bool, SourceLocation)
    case pointerNew(Expression, SourceLocation)
    case pointerDispose(Expression, SourceLocation)
    case halt(SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .empty(let l), .compound(_, let l), .assignment(_, _, let l),
             .procedureCall(_, let l), .if(_, _, _, let l), .while(_, _, let l),
             .repeat(_, _, let l), .for(_, _, _, _, _, let l), .case(_, _, let l),
             .with(_, _, let l), .forall(_, _, let l), .fork(_, let l),
             .join(let l), .port(_, _, let l), .allocate(_, _, let l),
             .duration(_, let l), .lock(_, let l), .unlock(_, let l),
             .seqoff(let l), .seqon(let l), .read(_, _, let l), .write(_, _, let l),
             .pointerNew(_, let l), .pointerDispose(_, let l), .halt(let l),
             .declarationBlock(_, let l):
            return l
        }
    }
}

public struct ForallHeader: Sendable {
    public var indexVariable: String
    public var initial: Expression
    public var final: Expression
    public var grouping: Expression?
    public init(indexVariable: String, initial: Expression, final: Expression, grouping: Expression?) {
        self.indexVariable = indexVariable
        self.initial = initial
        self.final = final
        self.grouping = grouping
    }
}

public struct ProcessSpawn: Sendable {
    public var processor: Expression?
    public var ports: [Expression]
    public var body: Statement
    public init(processor: Expression? = nil, ports: [Expression], body: Statement) {
        self.processor = processor
        self.ports = ports
        self.body = body
    }
}

// MARK: - Program

public struct CompiledUnit: Sendable {
    public var programName: String
    public var architecture: ArchitectureSpec?
    public var constants: [ConstDecl]
    public var types: [TypeDecl]
    public var globals: [VarDecl]
    public var routines: [RoutineDecl]
    public var body: [Statement]
    public var mainRoutineIndex: Int?
    public var sourceLines: Int
}

public struct ArchitectureSpec: Sendable, Hashable {
    public var topology: Topology
    public var parameter: Int
    public var location: SourceLocation
    public init(topology: Topology, parameter: Int, location: SourceLocation) {
        self.topology = topology
        self.parameter = parameter
        self.location = location
    }
}

public enum Topology: String, Sendable, CaseIterable {
    case shared = "Shared"
    case line = "Line"
    case ring = "Ring"
    case mesh2 = "Mesh2"
    case torus = "Torus"
    case mesh3 = "Mesh3"
    case hypercube = "Hypercube"
    case bus = "Bus"
    case star = "Star"
    case fullconnect = "Fullconnect"

    public var isSharedMemory: Bool { self == .shared }

    /// Total processor count for a given architecture parameter, per the manual.
    ///
    /// The source language limits architectures to 512 processors. Use checked
    /// arithmetic here so malformed or hostile source such as `Mesh3(999999999)`
    /// produces a normal diagnostic instead of trapping on integer overflow.
    public func processorCount(parameter n: Int) -> Int {
        guard n > 0 else { return 0 }

        func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int {
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            return overflow ? Int.max : value
        }

        switch self {
        case .shared, .line, .ring, .bus, .fullconnect:
            return n
        case .mesh2, .torus, .star:
            return checkedProduct(n, n)
        case .mesh3:
            return checkedProduct(checkedProduct(n, n), n)
        case .hypercube:
            guard n < Int.bitWidth - 1 else { return Int.max }
            return 1 << n
        }
    }
}
