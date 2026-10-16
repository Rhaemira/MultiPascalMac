// Created by Amirali Yazdani on 10/16/26.
import Foundation

public struct Parser {
    private var tokens: [Token]
    private var position: Int = 0
    private var lineCount: Int

    public init(source: String) throws {
        self.tokens = try Lexer.tokenize(source)
        self.lineCount = tokens.last.map { $0.location.line } ?? 0
    }

    // MARK: - Token helpers

    private var current: Token { tokens[min(position, tokens.count - 1)] }

    private func peek(_ offset: Int) -> Token {
        tokens[min(position + offset, tokens.count - 1)]
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = current
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    private func check(_ symbol: Symbol) -> Bool { current.isSymbol(symbol) }

    private func check(_ keyword: Keyword) -> Bool { current.isKeyword(keyword) }

    @discardableResult
    private mutating func match(_ symbol: Symbol) -> Bool {
        guard check(symbol) else { return false }
        _ = advance()
        return true
    }

    @discardableResult
    private mutating func match(_ keyword: Keyword) -> Bool {
        guard check(keyword) else { return false }
        _ = advance()
        return true
    }

    private mutating func expect(_ symbol: Symbol) throws {
        guard check(symbol) else {
            let expected: String
            switch symbol {
            case .semicolon: expected = "A semicolon \";\""
            case .equal: expected = "An equals sign \"=\""
            case .assign: expected = "an assignment operator \":=\""
            case .dot: expected = "the final program period ."
            default: expected = "the symbol \"\(symbol.rawValue)\""
            }
            throw MPWinError.syntax(Diagnostic(.error, "\(expected) was expected but not found.", current.location))
        }
        _ = advance()
    }

    private mutating func expect(_ keyword: Keyword) throws {
        guard check(keyword) else {
            throw MPWinError.syntax(Diagnostic(.error, "The keyword \"\(keyword.rawValue)\" was expected but not found.", current.location))
        }
        _ = advance()
    }

    private mutating func expectIdentifier() throws -> String {
        guard case .identifier(let name) = current.kind else {
            throw MPWinError.syntax(Diagnostic(.error, "IDENTIFIER was expected but not found.", current.location))
        }
        _ = advance()
        return name
    }

    private func identifierName(afterKeyword keyword: Keyword) -> String? {
        // Allows `endproc` style keywords to be used as identifiers, as the original does.
        guard let token = tokens[safe: position + 1] else { return nil }
        if case .keyword(let value) = token.kind, value == keyword { return keyword.rawValue }
        if case .identifier = token.kind { return token.text }
        return nil
    }

    /// `architecture` is not a reserved word in the original; it is recognised positionally.
    private func atArchitectureIdentifier() -> Bool {
        guard case .identifier(let name) = current.kind else { return false }
        return name.lowercased() == "architecture"
    }

    private func checkSharedMarker() -> Bool {
        if case .identifier(let name) = current.kind {
            return name.lowercased() == "shared"
        }
        return false
    }

    // MARK: - Entry point

    public mutating func parseProgram() throws -> CompiledUnit {
        try expect(.program)
        let programName = try expectIdentifier()
        try expect(.semicolon)

        var architecture: ArchitectureSpec?
        if atArchitectureIdentifier() {
            let location = current.location
            _ = advance()
            guard case .identifier(let topologyName) = current.kind else {
                throw MPWinError.syntax(Diagnostic(.error, "A built-in multicomputer topology was expected but not found", current.location))
            }
            _ = advance()
            guard let topology = Topology.allCases.first(where: {
                $0.rawValue.lowercased() == topologyName.lowercased()
            }) else {
                throw MPWinError.syntax(Diagnostic(.error, "A built-in multicomputer topology was expected but not found", current.location))
            }
            try expect(.lparen)
            guard case .integerLiteral(let value) = current.kind else {
                throw MPWinError.syntax(Diagnostic(.error, "Multicomputer architecture parameters must be positive integer values", current.location))
            }
            _ = advance()
            try expect(.rparen)
            try expect(.semicolon)
            guard value > 0 else {
                throw MPWinError.syntax(Diagnostic(.error, "Multicomputer architecture parameters must be positive integer values", location))
            }
            let total = topology.processorCount(parameter: value)
            guard total <= 512 else {
                throw MPWinError.semantic(Diagnostic(.error, "Multicomputer architecture parameters must be positive integer values", location))
            }
            architecture = ArchitectureSpec(topology: topology, parameter: value, location: location)
        }

        var constants: [ConstDecl] = []
        var types: [TypeDecl] = []
        var globals: [VarDecl] = []
        var routines: [RoutineDecl] = []

        // Declaration part, in any order.
        declarationLoop: while true {
            switch current.kind {
            case .keyword(.const):
                _ = advance()
                constants.append(contentsOf: try parseConstantGroup())
            case .keyword(.type):
                _ = advance()
                types.append(contentsOf: try parseTypeGroup())
            case .keyword(.var):
                _ = advance()
                globals.append(contentsOf: try parseVarGroup())
            case .keyword(.procedure), .keyword(.function):
                routines.append(try parseRoutine())
            case .keyword(.begin):
                break declarationLoop
            case .identifier(let name) where name.lowercased() == "shared":
                // Some MPWin teaching examples use an explicit `Shared` section
                // before top-level variables. Top-level variables are already
                // shared in this implementation, so the marker itself is a
                // declaration-section heading rather than a storage qualifier.
                _ = advance()
                if !check(.procedure) && !check(.function) && !check(.begin) && !current.isEOF {
                    globals.append(contentsOf: try parseVarGroup())
                }
            default:
                throw MPWinError.syntax(Diagnostic(.error, "PROGRAM INCOMPLETE", current.location))
            }
        }

        try expect(.begin)
        let body = try parseStatementList(until: [.end])
        try expect(.end)
        // A Pascal program is terminated by END followed by a mandatory period.
        try expect(.dot)
        if !current.isEOF {
            throw MPWinError.syntax(Diagnostic(.error, "PROGRAM INCOMPLETE", current.location))
        }

        return CompiledUnit(
            programName: programName,
            architecture: architecture,
            constants: constants,
            types: types,
            globals: globals,
            routines: routines,
            body: body,
            mainRoutineIndex: nil,
            sourceLines: max(lineCount, 1)
        )
    }

    // MARK: - Declarations

    private mutating func parseConstantGroup() throws -> [ConstDecl] {
        var result: [ConstDecl] = []
        while true {
            let names = try parseIdentifierList()
            var declared: TypeNode?
            if match(.colon) { declared = try parseType() }
            try expect(.equal)
            let value = try parseExpression()
            for name in names {
                result.append(ConstDecl(name: name, type: declared, value: value))
            }
            try expect(.semicolon)
            if isDeclarationSectionBoundary { break }
        }
        return result
    }

    private mutating func parseTypeGroup() throws -> [TypeDecl] {
        var result: [TypeDecl] = []
        while true {
            let names = try parseIdentifierList()
            try expect(.equal)
            let type = try parseType()
            for name in names {
                result.append(TypeDecl(name: name, type: type))
            }
            try expect(.semicolon)
            if isDeclarationSectionBoundary { break }
        }
        return result
    }

    private mutating func parseVarGroup() throws -> [VarDecl] {
        var result: [VarDecl] = []
        while true {
            let names = try parseIdentifierList()
            try expect(.colon)
            let type = try parseType()
            for name in names {
                result.append(VarDecl(names: [name], type: type))
            }
            try expect(.semicolon)
            if isDeclarationSectionBoundary { break }
        }
        return result
    }

    private var isDeclarationSectionBoundary: Bool {
        check(.const) || check(.type) || check(.var) || check(.begin) ||
        check(.procedure) || check(.function) || checkSharedMarker() || current.isEOF
    }

    private mutating func parseIdentifierList() throws -> [String] {
        var names: [String] = []
        repeat {
            names.append(try expectIdentifier())
        } while match(.comma)
        return names
    }

    private mutating func parseRoutine() throws -> RoutineDecl {
        let isFunction: Bool
        if match(.procedure) {
            isFunction = false
        } else {
            try expect(.function)
            isFunction = true
        }
        let location = current.location
        let name = try expectIdentifier()
        var params: [ParamDecl] = []
        // Pascal permits parameterless procedures/functions without parentheses:
        // `procedure Foo;` / `function Bar: Integer;`. Explicit `()` is also accepted.
        if match(.lparen) {
            if !check(.rparen) {
                repeat {
                    var isVar = false
                    if match(.var) {
                        isVar = true
                    } else {
                        _ = match(.const)
                    }
                    let paramNames = try parseIdentifierList()
                    try expect(.colon)
                    let type = try parseType()
                    for param in paramNames {
                        params.append(ParamDecl(name: param, type: type, isVar: isVar))
                    }
                } while match(.semicolon)
            }
            try expect(.rparen)
        }

        var returnType: TypeNode?
        if isFunction {
            try expect(.colon)
            returnType = try parseType()
        } else if check(.colon) {
            _ = advance()
            returnType = try parseType()
        }
        // Pascal requires a semicolon after the complete procedure/function header.
        try expect(.semicolon)

        var locals: [VarDecl] = []
        declarationLoop: while true {
            if match(.var) {
                while !check(.begin), !check(.const), !check(.type), !check(.procedure),
                      !check(.function), !current.isEOF {
                    locals.append(contentsOf: try parseVarGroup())
                }
            } else if check(.const) || check(.type) {
                throw MPWinError.syntax(Diagnostic(.error,
                    "Routine-local CONST/TYPE sections are not supported by this MPWin parser.",
                    current.location))
            } else {
                break declarationLoop
            }
        }

        try expect(.begin)
        let body = try parseStatementList(until: [.end])
        try expect(.end)
        // Both procedure and function declarations require a trailing semicolon.
        try expect(.semicolon)
        if returnType != nil { /* retained in `RoutineDecl.resultType` */ }
        return RoutineDecl(name: name, isFunction: isFunction, params: params, locals: locals,
                           body: body, resultType: returnType, location: location, isNested: false)
    }

    // MARK: - Types

    private mutating func parseType() throws -> TypeNode {
        let location = current.location
        switch current.kind {
        case .keyword(.integer):
            _ = advance(); return .integer(location)
        case .keyword(.real):
            _ = advance(); return .real(location)
        case .keyword(.boolean):
            _ = advance(); return .boolean(location)
        case .keyword(.char):
            _ = advance(); return .char(location)
        case .keyword(.spinlock):
            _ = advance(); return .spinlock(location)
        case .keyword(.channel):
            _ = advance()
            try expect(.of)
            return .channelOf(try parseType(), location)
        case .keyword(.array):
            _ = advance()
            try expect(.lbracket)
            var lowerBounds: [Expression?] = []
            var upperBounds: [Expression] = []
            repeat {
                if check(.dot), peek(1).isSymbol(.dot) {
                    // `array [..n]` open lower bound means the minimum integer.
                    _ = advance(); _ = advance()
                    lowerBounds.append(nil)
                } else {
                    lowerBounds.append(try parseExpression())
                    try expect(.range)
                }
                upperBounds.append(try parseExpression())
            } while match(.comma)
            try expect(.rbracket)
            try expect(.of)
            return .array(lower: lowerBounds, upper: upperBounds, element: try parseType(), location)
        case .keyword(.record):
            _ = advance()
            var fields: [FieldDecl] = []
            while !check(.end), !current.isEOF {
                let names = try parseIdentifierList()
                try expect(.colon)
                let type = try parseType()
                fields.append(FieldDecl(names: names, type: type))
                try expect(.semicolon)
            }
            try expect(.end)
            return .record(fields, location)
        case .symbol(.caret):
            _ = advance()
            return .pointer(try parseType(), location)
        case .identifier(let name):
            _ = advance()
            return .named(name, location)
        default:
            throw MPWinError.syntax(Diagnostic(.error, "The first word in each type definition must be an identifier or one of the following: ARRAY, RECORD, ^, CHANNEL.", current.location))
        }
    }

    // MARK: - Statements

    /// Parses a Pascal statement sequence and enforces semicolons as separators.
    /// A final semicolon before the terminator is allowed, as are repeated empty
    /// separators. For CASE arms, the next label or ELSE ends the arm, but only
    /// after the prior statement has been separated correctly.
    private mutating func parseStatementList(until terminators: [Keyword],
                                             stopAtCaseLabel: Bool = false) throws -> [Statement] {
        var statements: [Statement] = []
        while !current.isEOF {
            if terminators.contains(where: { check($0) }) { break }
            if stopAtCaseLabel && (check(.else) || isCaseLabelBoundary) { break }
            if match(.semicolon) { continue }

            statements.append(try parseStatement())
            if current.isEOF || terminators.contains(where: { check($0) }) { break }
            // For CASE arms, ELSE/another label are delimiters that still require
            // the semicolon separator after the preceding statement.
            try expect(.semicolon)
        }
        return statements
    }

    private var isCaseLabelBoundary: Bool {
        (isCaseLabelStart() || check(.minus)) && peek(1).isSymbol(.colon)
    }

    private mutating func parseStatement() throws -> Statement {
        let location = current.location

        // Leave a bare semicolon in place: in a controlled statement it denotes
        // an empty body, and the containing statement-list parser consumes it as
        // the separator after that complete statement.
        if check(.semicolon) {
            return .empty(location)
        }

        switch current.kind {
        case .keyword(.begin):
            _ = advance()
            let statements = try parseStatementList(until: [.end])
            try expect(.end)
            return .compound(statements, location)

        case .keyword(.var):
            // Statement block with local declarations.
            _ = advance()
            var locals: [VarDecl] = []
            while !check(.begin), !current.isEOF {
                locals.append(contentsOf: try parseVarGroup())
            }
            try expect(.begin)
            let statements = try parseStatementList(until: [.end])
            try expect(.end)
            // Local declarations are modelled as a nested compound with a declaration marker.
            return .compound([.declarationBlock(locals, location)] + statements, location)

        case .keyword(.if):
            _ = advance()
            let condition = try parseExpression()
            try expect(.then)
            let thenBranch = try parseStatement()
            var elseBranch: Statement?
            if match(.else) { elseBranch = try parseStatement() }
            return .if(condition, thenBranch, elseBranch, location)

        case .keyword(.while):
            _ = advance()
            let condition = try parseExpression()
            try expect(.do)
            return .while(condition, try parseStatement(), location)

        case .keyword(.repeat):
            _ = advance()
            let statements = try parseStatementList(until: [.until])
            try expect(.until)
            let condition = try parseExpression()
            return .repeat(statements, condition, location)

        case .keyword(.for):
            return try parseFor(location: location)

        case .keyword(.forall):
            return try parseForall(location: location)

        case .keyword(.case):
            return try parseCase(location: location)

        case .keyword(.with):
            _ = advance()
            let target = try parseExpression()
            try expect(.do)
            return .with(target, try parseStatement(), location)

        case .keyword(.fork):
            _ = advance()
            return .fork(try parseSpawn(), location)

        case .keyword(.join):
            _ = advance()
            return .join(location)

        case .keyword(.port):
            _ = advance()
            let ports = try parsePortList()
            return .port(ports, try parseStatement(), location)

        case .symbol(.at):
            _ = advance()
            let processor = try parseExpression()
            let spawn = try parseSpawn()
            return .allocate(processor, spawn, location)

        case .keyword(.duration):
            _ = advance()
            try expect(.lparen)
            let value = try parseExpression()
            try expect(.rparen)
            return .duration(value, location)

        case .keyword(.lock):
            _ = advance()
            try expect(.lparen)
            let target = try parseExpression()
            try expect(.rparen)
            return .lock(target, location)

        case .keyword(.unlock):
            _ = advance()
            try expect(.lparen)
            let target = try parseExpression()
            try expect(.rparen)
            return .unlock(target, location)

        case .keyword(.seqoff):
            _ = advance(); return .seqoff(location)
        case .keyword(.seqon):
            _ = advance(); return .seqon(location)

        case .keyword(.read), .keyword(.readln):
            let newline = current.isKeyword(.readln)
            _ = advance()
            let targets = try parseReadList()
            return .read(targets, newline, location)

        case .keyword(.write), .keyword(.writeln):
            let newline = current.isKeyword(.writeln)
            _ = advance()
            // Pascal permits `WriteLn;` with no argument list.
            let items = check(.lparen) ? try parseWriteReadList() : []
            return .write(items, newline, location)

        case .keyword(.new):
            _ = advance()
            try expect(.lparen)
            let target = try parseExpression()
            try expect(.rparen)
            return .pointerNew(target, location)

        case .keyword(.dispose):
            _ = advance()
            try expect(.lparen)
            let target = try parseExpression()
            try expect(.rparen)
            return .pointerDispose(target, location)

        case .keyword(.end):
            // An empty statement before END.
            return .empty(location)

        default:
            // Assignment or procedure call, or a bare `(@expr)` spawn form.
            let expression = try parseExpression()
            if let compound = Parser.compoundAssignment(current) {
                _ = advance()
                let value = try parseExpression()
                    // `x += e` is `x := x + e`; the target is re-read, as the original does.
                return .assignment(expression, .binary(compound, expression, value, location), location)
            }
            if check(.assign) {
                _ = advance()
                let value = try parseExpression()
                    return .assignment(expression, value, location)
            }
            // A parameterless Pascal procedure call is written as `Foo;`, not `Foo()`.
            // Convert a bare identifier statement into the same call AST used for `Foo()`.
            if case .identifier(let name, let callLocation) = expression {
                return .procedureCall(.call(name, [], callLocation), location)
            }
            return .procedureCall(expression, location)
        }
    }

    /// Operator text for the compound assignment symbols, or `nil` for anything else.
    private static func compoundAssignment(_ token: Token) -> String? {
        guard case .symbol(let symbol) = token.kind else { return nil }
        switch symbol {
        case .plusAssign: return "+"
        case .minusAssign: return "-"
        case .starAssign: return "*"
        case .slashAssign: return "/"
        default: return nil
        }
    }

    /// `Read`/`ReadLn` targets: plain variables, with an optional field width.
    private mutating func parseReadList() throws -> [Expression] {
        try expect(.lparen)
        var targets: [Expression] = []
        if !check(.rparen) {
            repeat {
                let value = try parseExpression()
                let expression = value
                if match(.colon) {
                    _ = try parseExpression()
                }
                targets.append(expression)
            } while match(.comma)
        }
        try expect(.rparen)
        return targets
    }

    private mutating func parseSpawn() throws -> ProcessSpawn {
        var processor: Expression?
        var ports: [Expression] = []
        var parenthesized = false

        // Support the documented parenthesized prefix form: (@expr), (Port c1; c2),
        // or (@expr Port c1; c2), as well as the unparenthesized spelling.
        if check(.lparen) {
            let next = peek(1)
            if next.isSymbol(.at) || next.isKeyword(.port) {
                _ = advance()
                parenthesized = true
            }
        }

        if check(.at) {
            _ = advance()
            if check(.lparen) { _ = advance(); processor = try parseExpression(); try expect(.rparen) }
            else { processor = try parseExpression() }
        }

        if check(.port) {
            _ = advance()
            ports = try parsePortList()
        }

        if parenthesized {
            try expect(.rparen)
        }
        return ProcessSpawn(processor: processor, ports: ports, body: try parseStatement())
    }

    private mutating func parsePortList() throws -> [Expression] {
        var ports: [Expression] = []
        repeat {
            ports.append(try parseExpression())
        } while match(.semicolon)
        return ports
    }

    private mutating func parseFor(location: SourceLocation) throws -> Statement {
        try expect(.for)
        let variable = try expectIdentifier()
        try expect(.assign)
        let initial = try parseExpression()
        var ascending = true
        if match(.downto) {
            ascending = false
        } else {
            try expect(.to)
        }
        let final = try parseExpression()
        try expect(.do)
        let body = try parseStatement()
        return .for(variable, initial, final, ascending, body, location)
    }

    private mutating func parseForall(location: SourceLocation) throws -> Statement {
        try expect(.forall)
        let variable = try expectIdentifier()
        try expect(.assign)
        let initial = try parseExpression()
        try expect(.to)
        let final = try parseExpression()
        var grouping: Expression?
        if match(.grouping) {
            grouping = try parseExpression()
        }
        try expect(.do)
        let body = try parseSpawn()
        var forallBody = body.body
        if !body.ports.isEmpty { forallBody = .port(body.ports, forallBody, location) }
        if let processor = body.processor { forallBody = .allocate(processor, ProcessSpawn(ports: [], body: forallBody), location) }
        return .forall(ForallHeader(indexVariable: variable, initial: initial, final: final,
                                    grouping: grouping), forallBody, location)
    }

    private mutating func parseCase(location: SourceLocation) throws -> Statement {
        try expect(.case)
        let subject = try parseExpression()
        try expect(.of)
        var branches: [(Expression?, [Statement])] = []

        while isCaseLabelStart() || check(.minus) {
            var labels: [Expression] = []
            repeat {
                if current.isSymbol(.minus) {
                    let negLocation = current.location
                    _ = advance()
                    guard case .integerLiteral(let magnitude) = current.kind else {
                        throw MPWinError.syntax(Diagnostic(.error, "UNDEFINED CASE", negLocation))
                    }
                    _ = advance()
                    labels.append(.integerLiteral(-magnitude, negLocation))
                } else {
                    labels.append(try parseExpression())
                }
            } while match(.comma)
            try expect(.colon)

            let statements = try parseStatementList(until: [.end], stopAtCaseLabel: true)
            for label in labels {
                branches.append((label, statements))
            }
        }

        var elseStatements: [Statement]?
        if match(.else) {
            elseStatements = try parseStatementList(until: [.end])
        }
        try expect(.end)
        if let elseStatements {
            branches.append((nil, elseStatements))
        }
        return .case(subject, branches, location)
    }

    private func isCaseLabelStart() -> Bool {
        if case .integerLiteral = current.kind { return true }
        if case .stringLiteral = current.kind { return true }
        if case .identifier = current.kind { return true }
        if case .keyword(.nil) = current.kind { return true }
        return false
    }

    private mutating func parseWriteReadList() throws -> [WriteItem] {
        try expect(.lparen)
        var items: [WriteItem] = []
        if !check(.rparen) {
            repeat {
                let value = try parseExpression()
                var width: Expression?
                var decimals: Expression?
                if check(.colon) {
                    _ = advance()
                    width = try parseExpression()
                    if check(.colon) {
                        _ = advance()
                        decimals = try parseExpression()
                    }
                }
                items.append(WriteItem(value: value, width: width, decimals: decimals))
            } while match(.comma)
        }
        try expect(.rparen)
        return items
    }

    // MARK: - Expressions (precedence climbing)

    /// A binary operator together with the token that introduces it. Pascal's levels run
    /// from lowest to highest; the relational level is non-associative.
    private struct BinaryOperator: Sendable {
        var text: String
        var keyword: Keyword?
        var symbol: Symbol?
    }

    private static func keyword(_ text: String) -> BinaryOperator {
        BinaryOperator(text: text, keyword: Keyword(rawValue: text.uppercased()) ?? .or,
                       symbol: nil)
    }

    private static func symbol(_ text: String) -> BinaryOperator {
        BinaryOperator(text: text, keyword: nil, symbol: Symbol(rawValue: text))
    }

    // Operators are ordered from lowest to highest precedence. Relational
    // operators sit between logical AND and arithmetic, as in Pascal; placing
    // them at the bottom of the old parser accidentally made comparisons bind
    // tighter than addition (so `a + b > c` could not parse correctly).
    private static let precedenceTable: [[BinaryOperator]] = [
        [keyword("or"), keyword("xor")],
        [keyword("and")],
        [symbol("="), symbol("<>"), symbol("<"), symbol("<="), symbol(">"), symbol(">=")],
        [symbol("+"), symbol("-")],
        [symbol("*"), symbol("/"), keyword("div"), keyword("mod"), keyword("shl"), keyword("shr")],
    ]

    private static func matches(_ token: Token.Kind, _ op: BinaryOperator) -> Bool {
        if let keyword = op.keyword { return token == .keyword(keyword) }
        if let symbol = op.symbol { return token == .symbol(symbol) }
        return false
    }

    public mutating func parseExpression() throws -> Expression {
        try parseLevel(0)
    }

    private mutating func parseLevel(_ level: Int) throws -> Expression {
        guard level < Parser.precedenceTable.count else { return try parseUnary() }
        var left = try parseLevel(level + 1)
        var didMatchRelational = false
        while let op = Parser.precedenceTable[level].first(where: { Parser.matches(current.kind, $0) }) {
            if level == 2 && didMatchRelational {
                throw MPWinError.syntax(Diagnostic(.error,
                    "Relational operators cannot be chained without parentheses.", current.location))
            }
            let location = current.location
            _ = advance()
            let right = try parseLevel(level + 1)
            left = .binary(op.text, left, right, location)
            if level == 2 { didMatchRelational = true }
        }
        return left
    }

    private mutating func parseUnary() throws -> Expression {
        let location = current.location
        switch current.kind {
        case .symbol(.plus):
            _ = advance()
            return try parseUnary()
        case .symbol(.minus):
            _ = advance()
            return .unary("-", try parseUnary(), location)
        case .keyword(.not):
            _ = advance()
            return .unary("not", try parseUnary(), location)
        case .symbol(.caret):
            _ = advance()
            return try parsePostfix(.dereference(try parseUnary(), location))
        case .symbol(.at):
            // A bare `@` with no expression in front of a spawn.
            _ = advance()
            return .identifier("@", location)
        default:
            return try parsePrimary()
        }
    }

    private mutating func parsePostfix(_ expression: Expression) throws -> Expression {
        try Parser.applyPostfix(expression, to: tokens, position: &position)
    }

    private mutating func parsePrimary() throws -> Expression {
        let location = current.location
        switch current.kind {
        case .integerLiteral(let value):
            _ = advance()
            return .integerLiteral(value, location)
        case .realLiteral(let value):
            _ = advance()
            return .realLiteral(value, location)
        case .stringLiteral(let value):
            _ = advance()
            return .stringLiteral(value, location)
        case .keyword(.true):
            _ = advance(); return .booleanLiteral(true, location)
        case .keyword(.false):
            _ = advance(); return .booleanLiteral(false, location)
        case .keyword(.nil):
            _ = advance(); return .nilLiteral(location)
        case .keyword(.selfFn):
            _ = advance(); return .builtinCall(.selfProcess, [], location)
        case .keyword(.myid):
            _ = advance(); return .builtinCall(.myid, [], location)
        case .keyword(.clock):
            _ = advance(); return .builtinCall(.clock, [], location)
        case .keyword(.seqtime):
            _ = advance(); return .builtinCall(.seqtime, [], location)
        case .keyword(.abs), .keyword(.sqr), .keyword(.odd), .keyword(.chr), .keyword(.ord),
             .keyword(.succ), .keyword(.pred), .keyword(.round), .keyword(.trunc),
             .keyword(.sin), .keyword(.cos), .keyword(.exp), .keyword(.ln), .keyword(.sqrt),
             .keyword(.arctan), .keyword(.eof), .keyword(.eoln):
            let builtin = try parseBuiltin()
            var arguments: [Expression] = []
            if match(.lparen) {
                if !check(.rparen) {
                    repeat { arguments.append(try parseExpression()) } while match(.comma)
                }
                try expect(.rparen)
            } else {
                switch builtin {
                case .eof, .eoln: break
                default:
                    throw MPWinError.syntax(Diagnostic(.error,
                        "A built-in function argument in parentheses was expected.", location))
                }
            }
            return .builtinCall(builtin, arguments, location)
        case .symbol(.lparen):
            _ = advance()
            let inner = try parseExpression()
            try expect(.rparen)
            return try parsePostfix(inner)
        case .identifier(let name):
            _ = advance()
            if check(.lparen) {
                _ = advance()
                var args: [Argument] = []
                if !check(.rparen) {
                    repeat {
                        var isVar = false
                        if match(.var) {
                            isVar = true
                        } else {
                            _ = match(.const)
                        }
                        let value = try parseExpression()
                        args.append(Argument(isVar: isVar, value: value))
                    } while match(.comma) || match(.semicolon)
                }
                try expect(.rparen)
                return .call(name, args, location)
            }
            return try parsePostfix(.identifier(name, location))
        default:
            throw MPWinError.syntax(Diagnostic(.error, "Error in the indicated expression.", location))
        }
    }

    private mutating func parseBuiltin() throws -> Builtin {
        guard case .keyword(let keyword) = current.kind else {
            throw MPWinError.syntax(Diagnostic(.error, "Error in the indicated expression.", current.location))
        }
        _ = advance()
        switch keyword {
        case .abs: return .abs
        case .sqr: return .sqr
        case .odd: return .odd
        case .chr: return .chr
        case .ord: return .ord
        case .succ: return .succ
        case .pred: return .pred
        case .round: return .round
        case .trunc: return .trunc
        case .sin: return .sin
        case .cos: return .cos
        case .exp: return .exp
        case .ln: return .ln
        case .sqrt: return .sqrt
        case .arctan: return .arctan
        case .eof: return .eof
        case .eoln: return .eoln
        default:
            throw MPWinError.syntax(Diagnostic(.error, "Error in the indicated expression.", current.location))
        }
    }

    // MARK: - Postfix (field, index, channel test)

    public static func applyPostfix(_ expression: Expression, to tokens: [Token],
                                    position: inout Int) throws -> Expression {
        var result = expression
        while true {
            if tokens[safe: position].map({ $0.isSymbol(.dot) }) == true {
                // A `.` followed by an identifier is a field selector; `.=` is "not equal".
                if let next = tokens[safe: position + 1], case .identifier(let field) = next.kind {
                    _ = position
                    position += 2
                    result = .fieldAccess(result, field, next.location)
                    continue
                }
                return result
            }
            if tokens[safe: position].map({ $0.isSymbol(.lbracket) }) == true {
                let location = tokens[position].location
                var inner = Parser(tokens: tokens, start: position + 1)
                let indices = try inner.parseIndexList()
                guard inner.current.isSymbol(.rbracket) else {
                    throw MPWinError.syntax(Diagnostic(.error, "A semicolon \";\" was expected but not found.", location))
                }
                position = inner.position + 1
                result = .index(result, indices, location)
                continue
            }
            if tokens[safe: position].map({ $0.isSymbol(.caret) }) == true {
                let location = tokens[position].location
                position += 1
                result = .dereference(result, location)
                continue
            }
            if tokens[safe: position].map({ $0.isSymbol(.question) }) == true {
                let location = tokens[position].location
                position += 1
                result = .unary("chan?", result, location)
                continue
            }
            return result
        }
    }
}

// MARK: - Postfix-aware expression entry

extension Parser {
    private init(tokens: [Token], start: Int) {
        self.tokens = tokens
        self.position = start
        self.lineCount = tokens.last?.location.line ?? 0
    }

    private mutating func parseIndexList() throws -> [Expression] {
        var indices: [Expression] = []
        repeat {
            indices.append(try parseExpression())
        } while match(.comma)
        return indices
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
