// Expressions for breakpoint conditions, log points and watches.
//
//   A == $20 && [&70] != 0       registers, flags, memory
//   {&FFFE}                      a little-endian word
//   PC >= &8000 && X < 3
//   OSWRCH                       a symbol, when a resolver is given
//
// Numbers: &FF or $FF or 0xFF (hex), %1010 (binary), 42 (decimal).
// Names: A X Y S P PC, the flags C Z I D V N, CYCLES; anything else is
// looked up as a symbol. Operators, loosest first: || && == != < > <= >=
// | ^ & << >> + - * / % and the unary ! - ~. Values are integers; true
// is non-zero.

public struct DebugExpression: Sendable, CustomStringConvertible {
    public let source: String
    private let root: Node

    /// What an expression can see.
    public struct Context {
        public var register: (String) -> Int?
        public var readByte: (UInt16) -> UInt8
        public var symbol: (String) -> Int?

        public init(register: @escaping (String) -> Int?, readByte: @escaping (UInt16) -> UInt8,
                    symbol: @escaping (String) -> Int? = { _ in nil }) {
            self.register = register
            self.readByte = readByte
            self.symbol = symbol
        }
    }

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var message: String
        public var description: String { message }
    }

    public struct EvaluationError: Error, CustomStringConvertible, Equatable {
        public var message: String
        public var description: String { message }
    }

    indirect enum Node: Sendable {
        case number(Int)
        case name(String)
        case byte(Node)
        case word(Node)
        case unary(String, Node)
        case binary(String, Node, Node)
    }

    public init(_ source: String) throws(ParseError) {
        self.source = source
        var parser = Parser(tokens: try Self.tokenise(source))
        root = try parser.expression()
        guard parser.atEnd else {
            throw ParseError(message: "unexpected \(parser.peek.map(\.text) ?? "end") in \"\(source)\"")
        }
    }

    public var description: String { source }

    public func evaluate(_ context: Context) throws(EvaluationError) -> Int {
        try Self.evaluate(root, context)
    }

    /// True if the expression is non-zero.
    public func isTrue(_ context: Context) throws(EvaluationError) -> Bool {
        try evaluate(context) != 0
    }

    private static func evaluate(_ node: Node, _ c: Context) throws(EvaluationError) -> Int {
        switch node {
        case .number(let n):
            return n
        case .name(let name):
            if let value = c.register(name.uppercased()) ?? c.symbol(name) {
                return value
            }
            throw EvaluationError(message: "unknown name \(name)")
        case .byte(let address):
            return Int(c.readByte(UInt16(truncatingIfNeeded: try evaluate(address, c))))
        case .word(let address):
            let a = UInt16(truncatingIfNeeded: try evaluate(address, c))
            return Int(c.readByte(a)) | Int(c.readByte(a &+ 1)) << 8
        case .unary(let op, let operand):
            let v = try evaluate(operand, c)
            switch op {
            case "!": return v == 0 ? 1 : 0
            case "-": return -v
            default: return ~v
            }
        case .binary(let op, let lhs, let rhs):
            let l = try evaluate(lhs, c)
            // Short circuit.
            if op == "&&" {
                guard l != 0 else { return 0 }
                return try evaluate(rhs, c) != 0 ? 1 : 0
            }
            if op == "||" {
                guard l == 0 else { return 1 }
                return try evaluate(rhs, c) != 0 ? 1 : 0
            }
            let r = try evaluate(rhs, c)
            switch op {
            case "==": return l == r ? 1 : 0
            case "!=": return l != r ? 1 : 0
            case "<": return l < r ? 1 : 0
            case ">": return l > r ? 1 : 0
            case "<=": return l <= r ? 1 : 0
            case ">=": return l >= r ? 1 : 0
            case "|": return l | r
            case "^": return l ^ r
            case "&": return l & r
            case "<<": return r >= 0 && r < 63 ? l << r : 0
            case ">>": return r >= 0 && r < 63 ? l >> r : 0
            case "+": return l &+ r
            case "-": return l &- r
            case "*": return l &* r
            case "/":
                guard r != 0 else { throw EvaluationError(message: "division by zero") }
                return l / r
            default:
                guard r != 0 else { throw EvaluationError(message: "division by zero") }
                return l % r
            }
        }
    }

    // MARK: Lexing

    struct Token: Equatable {
        enum Kind { case number, name, op }
        var kind: Kind
        var text: String
        var value = 0
    }

    private static let operators = ["||", "&&", "==", "!=", "<=", ">=", "<<", ">>",
                                    "<", ">", "|", "^", "&", "+", "-", "*", "/", "%", "!", "~",
                                    "(", ")", "[", "]", "{", "}"]

    static func tokenise(_ source: String) throws(ParseError) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0
        // After an operand, & is AND; otherwise it starts a hex number.
        var afterOperand: Bool {
            guard let last = tokens.last else { return false }
            return last.kind != .op || last.text == ")" || last.text == "]" || last.text == "}"
        }
        func digits(_ radix: Int, from start: Int) throws(ParseError) -> (Int, Int) {
            var j = start, value = 0
            while j < chars.count, let d = chars[j].hexDigitValue, d < radix {
                value = value &* radix &+ d
                j += 1
            }
            guard j > start else { throw ParseError(message: "bad number in \"\(source)\"") }
            return (value, j)
        }
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                i += 1
            } else if ch == "$" || (ch == "&" && !afterOperand && i + 1 < chars.count && chars[i + 1].isHexDigit) {
                let (value, j) = try digits(16, from: i + 1)
                tokens.append(Token(kind: .number, text: String(chars[i..<j]), value: value))
                i = j
            } else if ch == "%" && !afterOperand {
                let (value, j) = try digits(2, from: i + 1)
                tokens.append(Token(kind: .number, text: String(chars[i..<j]), value: value))
                i = j
            } else if ch == "0" && i + 1 < chars.count && (chars[i + 1] == "x" || chars[i + 1] == "X") {
                let (value, j) = try digits(16, from: i + 2)
                tokens.append(Token(kind: .number, text: String(chars[i..<j]), value: value))
                i = j
            } else if ch.isNumber {
                let (value, j) = try digits(10, from: i)
                tokens.append(Token(kind: .number, text: String(chars[i..<j]), value: value))
                i = j
            } else if ch.isLetter || ch == "_" || ch == "." || ch == "@" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." || chars[j] == "@" {
                    j += 1
                }
                tokens.append(Token(kind: .name, text: String(chars[i..<j])))
                i = j
            } else if let op = operators.first(where: { op in
                op.count <= chars.count - i && String(chars[i..<i + op.count]) == op
            }) {
                tokens.append(Token(kind: .op, text: op))
                i += op.count
            } else {
                throw ParseError(message: "unexpected \"\(ch)\" in \"\(source)\"")
            }
        }
        return tokens
    }

    // MARK: Parsing

    struct Parser {
        var tokens: [Token]
        var index = 0

        var atEnd: Bool { index == tokens.count }
        var peek: Token? { atEnd ? nil : tokens[index] }

        mutating func take(_ ops: Set<String>) -> String? {
            guard let t = peek, t.kind == .op, ops.contains(t.text) else { return nil }
            index += 1
            return t.text
        }

        static let levels: [Set<String>] = [["||"], ["&&"], ["==", "!=", "<", ">", "<=", ">="],
                                            ["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

        mutating func expression() throws(ParseError) -> Node {
            try binary(level: 0)
        }

        mutating func binary(level: Int) throws(ParseError) -> Node {
            guard level < Self.levels.count else { return try unary() }
            var lhs = try binary(level: level + 1)
            while let op = take(Self.levels[level]) {
                lhs = .binary(op, lhs, try binary(level: level + 1))
            }
            return lhs
        }

        mutating func unary() throws(ParseError) -> Node {
            if let op = take(["!", "-", "~"]) {
                return .unary(op, try unary())
            }
            return try primary()
        }

        mutating func primary() throws(ParseError) -> Node {
            guard let t = peek else { throw ParseError(message: "expression ends early") }
            index += 1
            switch t.kind {
            case .number:
                return .number(t.value)
            case .name:
                return .name(t.text)
            case .op:
                switch t.text {
                case "(":
                    let inner = try expression()
                    guard take([")"]) != nil else { throw ParseError(message: "missing )") }
                    return inner
                case "[":
                    let inner = try expression()
                    guard take(["]"]) != nil else { throw ParseError(message: "missing ]") }
                    return .byte(inner)
                case "{":
                    let inner = try expression()
                    guard take(["}"]) != nil else { throw ParseError(message: "missing }") }
                    return .word(inner)
                default:
                    throw ParseError(message: "unexpected \(t.text)")
                }
            }
        }
    }
}
