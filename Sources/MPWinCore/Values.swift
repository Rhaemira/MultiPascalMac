// Created by Amirali Yazdani on 10/16/26.
import Foundation

// MARK: - Runtime types

public indirect enum TypeInfo: Sendable, Equatable {
    case integer
    case real
    case boolean
    case character
    case spinlock
    case channelOf(TypeInfo)
    case pointer(TypeInfo)
    case array(element: TypeInfo, lower: [Int], upper: [Int])
    case record([RecordField])

    public var isChannel: Bool {
        if case .channelOf = self { return true }
        return false
    }

    public var isNumeric: Bool {
        self == .integer || self == .real
    }

    public var isReal: Bool { self == .real }

    /// The type obtained by dropping the outermost `count` array dimensions.
    public func droppingDimensions(_ count: Int) -> TypeInfo {
        guard count > 0 else { return self }
        guard case .array(let element, let lower, let upper) = self else { return self }
        if lower.count > count {
            return .array(element: element, lower: Array(lower.dropFirst(count)),
                          upper: Array(upper.dropFirst(count)))
        }
        return element
    }

    /// Number of memory locations occupied.
    public var footprint: Int {
        switch self {
        case .integer, .real, .boolean, .character, .spinlock, .channelOf, .pointer:
            return 1
        case .array(let element, let lower, let upper):
            var count = 1
            for (low, high) in zip(lower, upper) {
                let extent = max(0, high - low + 1)
                let (next, overflow) = count.multipliedReportingOverflow(by: extent)
                if overflow { return Int.max }
                count = next
            }
            let (total, overflow) = count.multipliedReportingOverflow(by: element.footprint)
            return overflow ? Int.max : total
        case .record(let fields):
            return fields.reduce(0) { partial, field in
                let (total, overflow) = partial.addingReportingOverflow(field.type.footprint)
                return overflow ? Int.max : total
            }
        }
    }

    public static func == (lhs: TypeInfo, rhs: TypeInfo) -> Bool {
        switch (lhs, rhs) {
        case (.integer, .integer), (.real, .real), (.boolean, .boolean),
             (.character, .character), (.spinlock, .spinlock):
            return true
        case (.channelOf(let a), .channelOf(let b)): return a == b
        case (.pointer(let a), .pointer(let b)): return a == b
        case (.array(let e1, let l1, let u1), .array(let e2, let l2, let u2)):
            return e1 == e2 && l1 == l2 && u1 == u2
        case (.record(let a), .record(let b)):
            return a == b
        default:
            return false
        }
    }

    // MARK: Layout

    /// The type reached by indexing an array-typed value with the given subscripts.
    public var elementType: TypeInfo {
        if case .array(let element, _, _) = self { return element }
        return .integer
    }

    /// The type of one array dimension, i.e. the array type obtained by dropping
    /// the outermost subscript of a multidimensional array.
    public var slicedType: TypeInfo {
        if case .array(let element, let lower, let upper) = self {
            if lower.count > 1 {
                return .array(element: element, lower: Array(lower.dropFirst()),
                              upper: Array(upper.dropFirst()))
            }
            return element
        }
        return .integer
    }

    /// Number of subscripts an array type accepts.
    public var rank: Int {
        if case .array(_, let lower, _) = self { return lower.count }
        return 0
    }

    /// Extent of dimension `dimension`, or `nil` when out of range.
    public func extent(ofDimension dimension: Int) -> Int? {
        guard case .array(_, let lower, let upper) = self,
              dimension < lower.count else { return nil }
        return upper[dimension] - lower[dimension] + 1
    }

    public func lowerBound(ofDimension dimension: Int) -> Int? {
        guard case .array(_, let lower, _) = self, dimension < lower.count else { return nil }
        return lower[dimension]
    }

    /// Linear element offset for the given already-zero-based subscripts.
    public func linearOffset(_ subscripts: [Int]) -> Int? {
        guard case .array(let element, let lower, let upper) = self,
              subscripts.count == lower.count else { return nil }
        var offset = 0
        for (index, value) in subscripts.enumerated() {
            let extent = upper[index] - lower[index] + 1
            guard extent > 0, value >= 0, value < extent else { return nil }
            offset = offset * extent + value
        }
        return offset * element.footprint
    }

    public func field(named name: String) -> RecordField? {
        guard case .record(let fields) = self else { return nil }
        let target = name.lowercased()
        return fields.first { $0.name.lowercased() == target }
    }

    /// Default value a freshly declared location starts with.
    public var defaultValue: Value {
        switch self {
        case .integer: return .integer(0)
        case .real: return .real(0)
        case .boolean: return .boolean(false)
        case .character: return .character(" ")
        case .spinlock: return .boolean(false)
        case .channelOf: return .channel(ChannelBuffer())
        case .pointer: return .pointer(nil)
        case .array: return .void
        case .record: return .void
        }
    }
}

public struct RecordField: Sendable, Equatable {
    public var name: String
    public var offset: Int
    public var type: TypeInfo
    public init(name: String, offset: Int, type: TypeInfo) {
        self.name = name
        self.offset = offset
        self.type = type
    }
}

// MARK: - Runtime values

/// Channel buffers and pointer cells are reference-typed. The simulator is single-threaded
/// by construction (one global virtual clock), so unchecked conformance is sound here.
public final class ChannelBuffer: @unchecked Sendable {
    public var queue: [Value] = []
    /// Receiver process/port binding recorded by the `Port` statement.
    public var receiverProcess: Int?
    public var receiverPortIndex: Int?
    /// Number of packets the manual's `Channel` support allows in flight.
    public var capacity: Int = 1
    public init() {}
}

public final class CellBox: @unchecked Sendable, Hashable {
    /// Slot zero; `New` allocates exactly one location in the original.
    public static let maximumSimulatedCells = 1_000_000
    public var value: Value
    /// Further locations, used when a pointer is indexed as an array.
    public var extra: [Value?] = []
    public init(_ value: Value) { self.value = value }
    public static func == (lhs: CellBox, rhs: CellBox) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    public subscript(index: Int) -> Value? {
        get {
            guard index >= 0 && index < Self.maximumSimulatedCells else { return nil }
            return index == 0 ? value : (index < extra.count ? extra[index] : nil)
        }
        set {
            guard index >= 0 && index < Self.maximumSimulatedCells else { return }
            if index == 0 { value = newValue ?? .void }
            else {
                while extra.count <= index { extra.append(nil) }
                extra[index] = newValue
            }
        }
    }
}

public enum Value: Sendable {
    case integer(Int)
    case real(Double)
    case boolean(Bool)
    case character(Character)
    case string(String)
    case array([Value])
    case record([Value])            // ordered by field offset
    case pointer(CellBox?)
    case channel(ChannelBuffer)
    case void

    public var type: TypeInfo {
        switch self {
        case .integer: return .integer
        case .real: return .real
        case .boolean: return .boolean
        case .character: return .character
        case .string: return .character
        case .array: return .array(element: .integer, lower: [0], upper: [0]) // refined by static type
        case .record: return .record([])
        case .pointer: return .pointer(.integer)
        case .channel: return .channelOf(.integer)
        case .void: return .integer
        }
    }

    public var truthy: Bool {
        switch self {
        case .boolean(let flag): return flag
        case .integer(let value): return value != 0
        case .real(let value): return value != 0
        case .character(let character): return character != "\0"
        case .string(let string): return !string.isEmpty
        default: return true
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .integer, .real: return true
        default: return false
        }
    }

    public var isReal: Bool {
        if case .real = self { return true }
        return false
    }

    public var asInteger: Int? {
        switch self {
        case .integer(let value): return value
        case .character(let character): return Int(character.unicodeScalars.first?.value ?? 0)
        case .string(let string) where string.count == 1:
            return string.unicodeScalars.first.map { Int($0.value) }
        case .boolean(let flag): return flag ? 1 : 0
        case .real(let value):
            guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
            return Int(value)
        default: return nil
        }
    }

    public var asReal: Double {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return 0
        }
    }

    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.integer(let a), .integer(let b)): return a == b
        case (.real(let a), .real(let b)): return a == b
        case (.integer(let a), .real(let b)): return Double(a) == b
        case (.real(let a), .integer(let b)): return a == Double(b)
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.character(let a), .character(let b)): return a == b
        case (.void, .void): return true
        default: return false
        }
    }
}

// MARK: - Memory

public enum Segment: Sendable, Hashable {
    /// Shared memory: the single segment of a `Shared` architecture, segment 0 of any
    /// other topology, and therefore always the same storage.
    case shared
    /// A slot in one of the running process's frames, identified by its index in the
    /// call stack so a `var` parameter keeps referring to the caller's variable.
    case local(frame: Int)
    /// A location reached through a `^` dereference.
    case cell(CellBox)
}

public struct MemoryRef: Sendable, Hashable {
    public var segment: Segment
    public var address: Int
    public init(segment: Segment, address: Int) {
        self.segment = segment
        self.address = address
    }
    public static let sharedZero = MemoryRef(segment: .shared, address: 0)
    public static func localSlot(_ slot: Int, frame: Int) -> MemoryRef {
        MemoryRef(segment: .local(frame: frame), address: slot)
    }
}

// MARK: - Output formatting

public enum Format {
    /// `WRITE`/`WRITELN` field formatting: `V`, `V:W`, `V:W:D`.
    public static func write(_ value: Value, width: Int?, decimals: Int?) -> String {
        switch value {
        case .real(let number):
            if let width, let decimals {
                return String(format: "%\(width).\(decimals)f", number)
            }
            if let width {
                return String(format: "%\(width).\(max(1, width - 6))g", number)
            }
            return plain(number)

        case .integer(let number):
            if let width, decimals != nil {
                return String(format: "%\(width).0f", Double(number))
            }
            if let width {
                return pad(String(number), to: width)
            }
            return String(number)

        case .boolean(let flag):
            return pad(flag ? "TRUE" : "FALSE", to: width)

        case .character(let character):
            return pad(String(character), to: width)

        case .string(let string):
            return pad(string, to: width)

        case .void:
            return ""

        case .channel:
            return "CHANNEL"

        case .pointer(let box):
            guard let box else { return "NIL POINTER" }
            switch box.value {
            case .integer(let number): return "  TO^  \(number)"
            default: return "  TO^  "
            }

        case .array(let elements):
            return elements.map { write($0, width: nil, decimals: nil) }.joined(separator: " ")

        case .record(let fields):
            return fields.map { write($0, width: nil, decimals: nil) }.joined(separator: " ")
        }
    }

    private static func plain(_ number: Double) -> String {
        if number == number.rounded() && abs(number) < 1e15 {
            return String(Int(number))
        }
        var text = String(format: "%.11g", number)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    private static func pad(_ text: String, to width: Int?) -> String {
        guard let width, text.count < width else { return text }
        return String(repeating: " ", count: width - text.count) + text
    }
}

// MARK: - Arithmetic

/// Operators are stored in the AST as text so the loader can fold constants and the
/// machine can evaluate them through the same code path.
public enum Operations {
    /// Folds or evaluates a binary operator over already-evaluated operands.
    public static func binary(_ op: String, _ lhs: Value, _ rhs: Value,
                              _ location: SourceLocation) throws -> Value {
        switch op {
        case "+", "-", "*", "/":
            return try arithmetic(op, lhs, rhs, location)
        case "div", "mod", "shl", "shr", "and", "or", "xor":
            return try integer(op, lhs, rhs, location)
        case "=", "<>", "<", "<=", ">", ">=":
            return try compare(op, lhs, rhs, location)
        default:
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }
    }

    private static func arithmetic(_ op: String, _ lhs: Value, _ rhs: Value,
                                   _ location: SourceLocation) throws -> Value {
        guard lhs.isNumeric && rhs.isNumeric else {
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }

        // Pascal's `/` produces real division. Mixed INTEGER/REAL arithmetic
        // must promote both operands instead of truncating the REAL to INTEGER.
        if op == "/" || lhs.isReal || rhs.isReal {
            let a = lhs.asReal
            let b = rhs.asReal
            if op == "/", b == 0 {
                throw MPWinError.runtime(Diagnostic(.error, "Real division by zero.", location))
            }
            let result: Double
            switch op {
            case "+": result = a + b
            case "-": result = a - b
            case "*": result = a * b
            case "/": result = a / b
            default:
                throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
            }
            guard result.isFinite else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return .real(result)
        }

        guard case .integer(let a) = lhs, case .integer(let b) = rhs else {
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }
        let result: (partialValue: Int, overflow: Bool)
        switch op {
        case "+": result = a.addingReportingOverflow(b)
        case "-": result = a.subtractingReportingOverflow(b)
        case "*": result = a.multipliedReportingOverflow(by: b)
        default:
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }
        guard !result.overflow else {
            throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
        }
        return .integer(result.partialValue)
    }

    private static func integer(_ op: String, _ lhs: Value, _ rhs: Value,
                                _ location: SourceLocation) throws -> Value {
        // Logical operators preserve BOOLEAN values. The same operators also
        // support integer bitwise operations in the MPWin dialect.
        if case .boolean(let a) = lhs, case .boolean(let b) = rhs {
            switch op {
            case "and": return .boolean(a && b)
            case "or": return .boolean(a || b)
            case "xor": return .boolean(a != b)
            default: break
            }
        }

        guard case .integer(let a) = lhs, case .integer(let b) = rhs else {
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }
        switch op {
        case "div":
            guard b != 0 else {
                throw MPWinError.runtime(Diagnostic(.error, "Integer division by zero.", location))
            }
            guard !(a == Int.min && b == -1) else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return .integer(a / b)
        case "mod":
            guard b != 0 else {
                throw MPWinError.runtime(Diagnostic(.error, "Integer division by zero.", location))
            }
            guard !(a == Int.min && b == -1) else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return .integer(a % b)
        case "shl", "shr":
            guard b >= 0 && b < Int.bitWidth else {
                throw MPWinError.runtime(Diagnostic(.error, "EXPRESSION EVALUATION OVERFLOW", location))
            }
            return .integer(op == "shl" ? (a << b) : (a >> b))
        case "and": return .integer(a & b)
        case "or": return .integer(a | b)
        case "xor": return .integer(a ^ b)
        default:
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }
    }

    private static func compare(_ op: String, _ lhs: Value, _ rhs: Value,
                                _ location: SourceLocation) throws -> Value {
        let order: Int
        if lhs.isNumeric && rhs.isNumeric {
            if lhs.isReal || rhs.isReal {
                order = lhs.asReal == rhs.asReal ? 0 : (lhs.asReal < rhs.asReal ? -1 : 1)
            } else {
                order = lhs.asInteger! == rhs.asInteger! ? 0 : (lhs.asInteger! < rhs.asInteger! ? -1 : 1)
            }
        } else if case .character(let a) = lhs, case .character(let b) = rhs {
            order = a == b ? 0 : (a < b ? -1 : 1)
        } else if case .boolean(let a) = lhs, case .boolean(let b) = rhs {
            // Use a stable ordering (FALSE < TRUE) so all comparison operators
            // share consistent equality semantics with numbers and characters.
            order = a == b ? 0 : (a ? 1 : -1)
        } else {
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }
        switch op {
        case "=": return .boolean(order == 0)
        case "<>": return .boolean(order != 0)
        case "<": return .boolean(order < 0)
        case "<=": return .boolean(order <= 0)
        case ">": return .boolean(order > 0)
        case ">=": return .boolean(order >= 0)
        default:
            throw MPWinError.semantic(Diagnostic(.error, "Error in the indicated expression.", location))
        }
    }

    /// `Write`/`WriteLn` write reals, integers, characters and booleans only.
    public static func isWritable(_ value: Value) -> Bool {
        switch value {
        case .integer, .real, .character, .boolean: return true
        default: return false
        }
    }
}

public enum RuntimeError: Error, CustomStringConvertible {
    case fault(String)

    public var description: String {
        if case .fault(let message) = self { return message }
        return ""
    }
}
