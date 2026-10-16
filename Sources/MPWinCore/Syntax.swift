// Created by Amirali Yazdani on 10/16/26.
import Foundation

// MARK: - Diagnostics

public struct SourceLocation: Sendable, Hashable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
    public static let unknown = SourceLocation(line: 0, column: 0)
}

public struct Diagnostic: Sendable, Error, CustomStringConvertible {
    public enum Severity: Sendable { case error, warning }

    public var severity: Severity
    public var message: String
    public var location: SourceLocation

    public init(_ severity: Severity, _ message: String, _ location: SourceLocation = .unknown) {
        self.severity = severity
        self.message = message
        self.location = location
    }

    public var description: String {
        guard location.line > 0 else { return message }
        return "\(location.line):\(location.column): \(message)"
    }
}

public enum MPWinError: Error, CustomStringConvertible {
    case syntax(Diagnostic)
    case semantic(Diagnostic)
    case runtime(Diagnostic)

    /// The bare diagnostic text, without the `Syntax error:` prefix.
    public var message: String {
        switch self {
        case .syntax(let d), .semantic(let d), .runtime(let d): return d.message
        }
    }

    public var location: SourceLocation {
        switch self {
        case .syntax(let d), .semantic(let d), .runtime(let d): return d.location
        }
    }

    public var description: String {
        switch self {
        case .syntax(let d): return "Syntax error: \(d)"
        case .semantic(let d): return "Semantic error: \(d)"
        case .runtime(let d): return "Runtime error: \(d)"
        }
    }
}

// MARK: - Keywords

/// The reserved-word table recovered verbatim from `MPWinP.exe`.
public enum Keyword: String, Sendable, CaseIterable {
    case and = "AND", array = "ARRAY", `begin` = "BEGIN", `case` = "CASE"
    case channel = "CHANNEL", `const` = "CONST", `div` = "DIV", `do` = "DO"
    case `downto` = "DOWNTO", `else` = "ELSE", `end` = "END", `for` = "FOR"
    case forall = "FORALL", fork = "FORK", function = "FUNCTION", grouping = "GROUPING"
    case `if` = "IF", join = "JOIN", mod = "MOD", `not` = "NOT", of = "OF"
    case or = "OR", port = "PORT", procedure = "PROCEDURE", program = "PROGRAM"
    case record = "RECORD", `repeat` = "REPEAT", shl = "SHL", shr = "SHR"
    case then = "THEN", `to` = "TO", type = "TYPE", until = "UNTIL", `var` = "VAR"
    case `while` = "WHILE", with = "WITH", `xor` = "XOR"

    case `false` = "FALSE", `true` = "TRUE", `nil` = "NIL"
    case char = "CHAR", boolean = "BOOLEAN", integer = "INTEGER", real = "REAL"
    case spinlock = "SPINLOCK"

    case abs = "ABS", sqr = "SQR", odd = "ODD", chr = "CHR", ord = "ORD", succ = "SUCC"
    case pred = "PRED", round = "ROUND", trunc = "TRUNC", sin = "SIN", cos = "COS"
    case exp = "EXP", ln = "LN", sqrt = "SQRT", arctan = "ARCTAN"
    case eof = "EOF", eoln = "EOLN"

    case selfFn = "%SELF", clock = "CLOCK", seqtime = "SEQTIME", myid = "%MYID"
    case read = "READ", readln = "READLN", write = "WRITE", writeln = "WRITELN"
    case `new` = "NEW", dispose = "DISPOSE", lock = "LOCK", unlock = "UNLOCK"
    case duration = "DURATION", seqoff = "%SEQOFF", seqon = "%SEQON"

    private static let lookup: [String: Keyword] = {
        var map: [String: Keyword] = [:]
        for keyword in Keyword.allCases {
            map[keyword.rawValue.lowercased()] = keyword
        }
        return map
    }()

    public static func named(_ text: String) -> Keyword? {
        lookup[text.lowercased()]
    }
}

// MARK: - Symbols

public enum Symbol: String, Sendable, CaseIterable {
    case plus = "+", minus = "-", star = "*", slash = "/"
    case equal = "=", less = "<", greater = ">"
    case lessEqual = "<=", greaterEqual = ">=", notEqual = "<>"
    case assign = ":=", plusAssign = "+=", minusAssign = "-="
    case starAssign = "*=", slashAssign = "/="
    case lparen = "(", rparen = ")"
    case lbracket = "[", rbracket = "]"
    case comma = ",", semicolon = ";", colon = ":", dot = "."
    case range = "..", caret = "^", at = "@", question = "?"
    case dcolon = "::"
}

// MARK: - Tokens

public struct Token: Sendable {
    public enum Kind: Sendable, Equatable {
        case identifier(String)
        case keyword(Keyword)
        case integerLiteral(Int)
        case realLiteral(Double)
        case stringLiteral(String)
        case symbol(Symbol)
        case endOfFile
    }

    public var kind: Kind
    public var text: String
    public var location: SourceLocation

    public init(kind: Kind, text: String, location: SourceLocation) {
        self.kind = kind
        self.text = text
        self.location = location
    }

    public var isEOF: Bool {
        if case .endOfFile = kind { return true }
        return false
    }

    /// Case-insensitive identifier test that also accepts reserved words used as names.
    public func isIdentifier(_ name: String) -> Bool {
        if case .identifier(let value) = kind { return value.lowercased() == name.lowercased() }
        return false
    }

    public func isSymbol(_ symbol: Symbol) -> Bool {
        if case .symbol(let value) = kind { return value == symbol }
        return false
    }

    public func isKeyword(_ keyword: Keyword) -> Bool {
        if case .keyword(let value) = kind { return value == keyword }
        return false
    }
}

// MARK: - Lexer

public struct Lexer {
    private let source: [UInt8]
    private var index: Int = 0
    private var line: Int = 1
    private var column: Int = 1

    public init(source: String) {
        self.source = Array(source.utf8)
    }

    public static func tokenize(_ source: String) throws -> [Token] {
        var lexer = Lexer(source: source)
        var tokens: [Token] = []
        while true {
            let token = try lexer.next()
            tokens.append(token)
            if token.isEOF { break }
        }
        return tokens
    }

    // MARK: Scanning

    private var current: UInt8? { index < source.count ? source[index] : nil }

    private func peek(_ offset: Int) -> UInt8? {
        let position = index + offset
        return position < source.count ? source[position] : nil
    }

    private mutating func advance() -> UInt8 {
        let byte = source[index]
        index += 1
        if byte == 0x0A {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return byte
    }

    private var location: SourceLocation { SourceLocation(line: line, column: column) }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte)
    }

    private mutating func skipTrivia() throws {
        while true {
            guard let byte = current else { return }
            if byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A {
                _ = advance()
                continue
            }
            // { ... } comment. Track nesting so braces inside comments cannot
            // leak stray tokens into the parser; report EOF before the final `}`.
            if byte == 0x7B {
                let start = location
                _ = advance()
                var depth = 1
                while let inner = current, depth > 0 {
                    if inner == 0x7B {
                        depth += 1
                        _ = advance()
                    } else if inner == 0x7D {
                        depth -= 1
                        _ = advance()
                    } else {
                        _ = advance()
                    }
                }
                guard depth == 0 else {
                    throw MPWinError.syntax(Diagnostic(.error, "Unterminated comment.", start))
                }
                continue
            }
            // (* ... *) comment
            if byte == 0x28, peek(1) == 0x2A {
                let start = location
                _ = advance(); _ = advance()
                while true {
                    guard let inner = current else {
                        throw MPWinError.syntax(Diagnostic(.error, "Unterminated comment.", start))
                    }
                    if inner == 0x2A, peek(1) == 0x29 {
                        _ = advance(); _ = advance()
                        break
                    }
                    _ = advance()
                }
                continue
            }
            // // comment
            if byte == 0x2F, peek(1) == 0x2F {
                while let inner = current, inner != 0x0A, inner != 0x0D { _ = advance() }
                continue
            }
            return
        }
    }

    public mutating func next() throws -> Token {
        try skipTrivia()
        let start = location
        guard let byte = current else {
            return Token(kind: .endOfFile, text: "", location: start)
        }

        if Self.isLetter(byte) {
            var text = ""
            while let b = current, Self.isLetterOrDigit(b) {
                text.append(Character(UnicodeScalar(advance())))
            }
            if let keyword = Keyword.named(text) {
                return Token(kind: .keyword(keyword), text: text, location: start)
            }
            return Token(kind: .identifier(text), text: text, location: start)
        }

        if byte == 0x25 { // '%' introduces %SELF, %MYID, %SEQOFF, %SEQON
            var text = "%"
            _ = advance()
            while let b = current, Self.isLetterOrDigit(b) {
                text.append(Character(UnicodeScalar(advance())))
            }
            if let keyword = Keyword.named(text) {
                return Token(kind: .keyword(keyword), text: text, location: start)
            }
            throw MPWinError.syntax(Diagnostic(.error, "Unknown directive \"\(text)\".", start))
        }

        if Self.isDigit(byte) || (byte == 0x2E && Self.isDigit(peek(1) ?? 0)) {
            return try scanNumber(start: start)
        }

        if byte == 0x27 { // single-quoted string, with doubled-quote escaping
            _ = advance()
            var bytes: [UInt8] = []
            while true {
                guard let b = current else {
                    throw MPWinError.syntax(Diagnostic(.error, "Unterminated string literal.", start))
                }
                if b == 0x27 {
                    _ = advance()
                    if current == 0x27 { // '' is an escaped quote
                        bytes.append(0x27)
                        _ = advance()
                        continue
                    }
                    break
                }
                if b == 0x0A || b == 0x0D {
                    throw MPWinError.syntax(Diagnostic(.error, "Unterminated string literal.", start))
                }
                bytes.append(advance())
            }
            let text = String(decoding: bytes, as: UTF8.self)
            return Token(kind: .stringLiteral(text), text: text, location: start)
        }

        // Operators, longest match first.
        if let symbol = try scanSymbol(start: start) {
            return Token(kind: .symbol(symbol), text: symbol.rawValue, location: start)
        }

        let bad = String(UnicodeScalar(byte))
        _ = advance()
        throw MPWinError.syntax(Diagnostic(.error, "Invalid character \"\(bad)\".", start))
    }

    private mutating func scanNumber(start: SourceLocation) throws -> Token {
        var text = ""
        var isReal = false
        while let b = current, Self.isDigit(b) {
            text.append(Character(UnicodeScalar(advance())))
        }
        // A '.' only starts a fraction when followed by a digit, so `1..n` stays a range.
        if current == 0x2E, let n = peek(1), Self.isDigit(n) {
            isReal = true
            text.append(Character(UnicodeScalar(advance())))
            while let b = current, Self.isDigit(b) {
                text.append(Character(UnicodeScalar(advance())))
            }
        }
        if let b = current, b == 0x65 || b == 0x45 { // e / E exponent
            let save = index, saveLine = line, saveColumn = column
            var exponent = String(UnicodeScalar(advance()))
            if let sign = current, sign == 0x2B || sign == 0x2D {
                exponent.append(Character(UnicodeScalar(advance())))
            }
            if let d = current, Self.isDigit(d) {
                while let b = current, Self.isDigit(b) {
                    exponent.append(Character(UnicodeScalar(advance())))
                }
                text += exponent
                isReal = true
            } else {
                index = save; line = saveLine; column = saveColumn
            }
        }
        if isReal {
            guard let value = Double(text), value.isFinite else {
                throw MPWinError.syntax(Diagnostic(.error, "Real literal is outside the finite numeric range.", start))
            }
            return Token(kind: .realLiteral(value), text: text, location: start)
        }
        guard let value = Int(text) else {
            throw MPWinError.syntax(Diagnostic(.error, "Error in Number", start))
        }
        return Token(kind: .integerLiteral(value), text: text, location: start)
    }

    private mutating func scanSymbol(start: SourceLocation) throws -> Symbol? {
        func take(_ count: Int) -> String {
            var text = ""
            for _ in 0..<count { text.append(Character(UnicodeScalar(advance()))) }
            return text
        }
        let first = current
        let second = peek(1)

        if first == 0x3A, second == 0x3A { _ = take(2); return .dcolon }
        if first == 0x3A, second == 0x3D { _ = take(2); return .assign }
        if first == 0x2B, second == 0x3D { _ = take(2); return .plusAssign }
        if first == 0x2D, second == 0x3D { _ = take(2); return .minusAssign }
        if first == 0x2A, second == 0x3D { _ = take(2); return .starAssign }
        if first == 0x2F, second == 0x3D { _ = take(2); return .slashAssign }
        if first == 0x3C, second == 0x3D { _ = take(2); return .lessEqual }
        if first == 0x3E, second == 0x3D { _ = take(2); return .greaterEqual }
        if first == 0x3C, second == 0x3E { _ = take(2); return .notEqual }
        if first == 0x2E, second == 0x2E { _ = take(2); return .range }

        guard let byte = first, let symbol = Symbol(rawValue: String(UnicodeScalar(byte))) else {
            return nil
        }
        _ = take(1)
        return symbol
    }
}
