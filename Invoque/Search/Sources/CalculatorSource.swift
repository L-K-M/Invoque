import Foundation

/// Offers one `= result` row with a copy action when the query is arithmetic,
/// e.g. `2+2` offers `= 4`.
///
/// Evaluation is a recursive-descent parser over a restricted arithmetic
/// grammar — deliberately not `NSExpression`: that evaluator raises
/// Objective-C exceptions on input it dislikes, which Swift cannot catch,
/// and it evaluates integer literals with integer division (`1/0` yields 0,
/// not an error). A hand parser computes `Double`s directly, so nothing
/// uncatchable is ever invoked and `/0` surfaces as a non-finite result that
/// offers no row.
final class CalculatorSource: ItemSource {

    // MARK: ItemSource

    /// Zero or one item: the evaluated result, or — when the query is a
    /// bare integer in some base — the base-conversion row. A bare number
    /// alone is not arithmetic, but it is the classic launcher question:
    /// "what is 0xFF?" / "what is 255 in hex?".
    func items(matching query: String) -> [Item] {
        if let conversion = Self.baseConversion(query) {
            return [conversion]
        }
        guard let evaluation = Self.evaluate(query) else { return [] }
        return [Item(
            // Whitespace is stripped from the id so `2 + 2` and `2+2` share
            // one identity; the displayed title keeps the user's spacing.
            id: Item.calculatorIDPrefix + evaluation.expression.filter { !$0.isWhitespace },
            title: "= \(evaluation.result)",
            subtitle: "Copy result to clipboard",
            icon: .symbol("equal.square"),
            action: .copyText(evaluation.result),
            matchText: "\(evaluation.expression) = \(evaluation.result)"
        )]
    }

    // MARK: Base conversion

    /// The bases a conversion row offers — radix, literal prefix, name.
    private static let conversionBases: [(radix: Int, prefix: String, name: String)] = [
        (16, "0x", "Hex"), (2, "0b", "Bin"), (8, "0o", "Oct"),
    ]

    /// One parsed query for conversion: the value plus which base the
    /// user typed (decimal queries carry nil — every base is news).
    private struct BaseQuery {
        let value: UInt64
        /// The radix the query itself spelled, nil for decimal input.
        let inputRadix: Int?
    }

    /// Parses a bare integer in any base: `255`, `0xFF`, `0b1010`, `0o17`.
    /// Decimal input needs at least two digits — a bare `7` is likelier an
    /// app search fragment than a conversion request, and the calc row is
    /// a head pin that would outrank real matches. No signs, no
    /// separators: a leading `-` or `_` disqualifies rather than guessing.
    private static func parseBaseQuery(_ trimmed: String) -> BaseQuery? {
        // Case-insensitive prefixes — `0X1A` is as natural as `0x1a`.
        let lowered = trimmed.lowercased()
        for (radix, prefix, _) in conversionBases where lowered.hasPrefix(prefix) {
            let digits = lowered.dropFirst(prefix.count)
            guard !digits.isEmpty,
                  let value = UInt64(digits, radix: radix) else { return nil }
            return BaseQuery(value: value, inputRadix: radix)
        }
        // ASCII digits only: `Character.isNumber` alone admits Unicode
        // digits that `UInt64` then declines — explicit beats relying on
        // the fallthrough.
        guard trimmed.count >= 2,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(trimmed) else { return nil }
        return BaseQuery(value: value, inputRadix: nil)
    }

    /// The conversion row for a bare-integer query: the title names the
    /// query's value in the most-wanted other base (hex for decimal
    /// input, decimal for a prefixed literal), the subtitle lists all
    /// three, and ⏎ copies the title's converted form. The id rides the
    /// `calc:` namespace — a head pin like every calculator answer, and
    /// frecency-ineligible for the same reason — keyed by value, so
    /// `0xFF` and `255` name the same row.
    private static func baseConversion(_ query: String) -> Item? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = parseBaseQuery(trimmed) else { return nil }

        // The headline target: hex from decimal, decimal from a literal.
        let headline: (radix: Int, prefix: String, name: String)
        if base.inputRadix == nil {
            headline = conversionBases[0]
        } else {
            headline = (10, "", "Dec")
        }
        let headlineText = headline.prefix
            + String(base.value, radix: headline.radix,
                     uppercase: headline.radix == 16)
        let title = "\(trimmed) = \(headlineText)"
        let subtitle = conversionBases
            .map { "\($0.name) \($0.prefix)\(String(base.value, radix: $0.radix, uppercase: $0.radix == 16))" }
            .joined(separator: " · ")
            + " — ⏎ copies \(headlineText)"
        return Item(
            id: Item.calculatorIDPrefix + "base:\(base.value)",
            title: title,
            subtitle: subtitle,
            icon: .symbol("number.square"),
            action: .copyText(headlineText),
            matchText: "\(trimmed) \(headlineText) \(subtitle)"
        )
    }

    // MARK: Evaluation

    /// A validated expression with its display string.
    private struct Evaluation {
        let expression: String
        let result: String
    }

    private static func evaluate(_ query: String) -> Evaluation? {
        let expression = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard looksMathy(expression), charsetIsValid(expression) else { return nil }
        guard let tokens = tokenize(expression), let value = parse(tokens) else { return nil }
        guard let display = displayString(for: value) else { return nil }
        return Evaluation(expression: expression, result: display)
    }

    // MARK: Gates

    /// Cap on evaluated length: deep paren nesting is a parse-time and
    /// stack-depth hazard with no legitimate launcher use.
    private static let maxExpressionLength = 200

    /// Cheap prefilter so plain words skip tokenizing: the query must open
    /// with a digit, an opening paren, a sign — or a letter that begins a
    /// known function name, so `sqrt(9)` counts. A bare function name with
    /// no parens still parses to nothing, so words like `exp` yield no row;
    /// `charsetIsValid` rejects names outside `knownFunctions`.
    private static func looksMathy(_ expression: String) -> Bool {
        guard !expression.isEmpty, expression.count <= Self.maxExpressionLength else { return false }
        guard let first = expression.first else { return false }
        return "0123456789(+-".contains(first)
            || knownFunctions.contains { $0.hasPrefix(String(first)) }
    }

    /// Every letter run must be a known function name; every other character
    /// must be plain math punctuation. Anything else (shell operators,
    /// quotes, `$()`, stray words like `rm`) is rejected here. This set must
    /// stay in lockstep with `Parser.functions` — a name that passes here but
    /// is unimplemented clears every gate and then silently produces no row.
    private static let knownFunctions: Set<String> = [
        "sqrt", "log", "ln", "exp", "abs",
    ]

    /// Digits, decimal point, the four basic operators, parens, comma, and
    /// spaces. `%` passes this gate (it reads as math) but is declined while
    /// tokenizing: the evaluator's grammar does not include it, and
    /// offering no row beats guessing at a meaning.
    private static let allowedPunctuation: Set<Character> = Set("0123456789.+-*/%(), ")

    private static func charsetIsValid(_ expression: String) -> Bool {
        var index = expression.startIndex
        while index < expression.endIndex {
            let char = expression[index]
            if char.isASCII && char.isLetter {
                var end = index
                while end < expression.endIndex, expression[end].isASCII, expression[end].isLetter {
                    expression.formIndex(after: &end)
                }
                guard knownFunctions.contains(String(expression[index ..< end])) else { return false }
                index = end
            } else {
                guard allowedPunctuation.contains(char) else { return false }
                expression.formIndex(after: &index)
            }
        }
        return true
    }

    // MARK: Tokens

    /// The only shapes the parser accepts. There is deliberately no comma or
    /// modulo token: multi-argument calls like `pow(2,3)` and `%` fail
    /// tokenizing and are never evaluated (see `allowedPunctuation`).
    private enum Token: Equatable {
        case number(Double)
        case function(String)
        case plus
        case minus
        case star
        case slash
        case leftParen
        case rightParen
    }

    private static func tokenize(_ expression: String) -> [Token]? {
        var tokens: [Token] = []
        var index = expression.startIndex
        while index < expression.endIndex {
            let char = expression[index]
            if char == " " {
                expression.formIndex(after: &index)
            } else if (char.isASCII && char.isNumber) || char == "." {
                guard let token = scanNumber(expression, from: &index) else { return nil }
                tokens.append(token)
            } else if char.isASCII && char.isLetter {
                var end = index
                while end < expression.endIndex, expression[end].isASCII, expression[end].isLetter {
                    expression.formIndex(after: &end)
                }
                tokens.append(.function(String(expression[index ..< end])))
                index = end
            } else if let token = singleCharToken(char) {
                tokens.append(token)
                expression.formIndex(after: &index)
            } else {
                // Commas, `%`, or anything the charset gate missed: decline.
                return nil
            }
        }
        return tokens.isEmpty ? nil : tokens
    }

    /// Scans a decimal literal: digits with at most one point and at least
    /// one digit, so `.` and `1.2.3` are rejected. Advances `index` past the
    /// literal.
    private static func scanNumber(_ expression: String, from index: inout String.Index) -> Token? {
        var end = index
        var dots = 0
        var digits = 0
        while end < expression.endIndex {
            let char = expression[end]
            if char.isASCII && char.isNumber {
                digits += 1
            } else if char == "." {
                dots += 1
            } else {
                break
            }
            expression.formIndex(after: &end)
        }
        guard digits > 0, dots <= 1, let value = Double(String(expression[index ..< end])) else {
            return nil
        }
        index = end
        return .number(value)
    }

    private static func singleCharToken(_ char: Character) -> Token? {
        switch char {
        case "+": return .plus
        case "-": return .minus
        case "*": return .star
        case "/": return .slash
        case "(": return .leftParen
        case ")": return .rightParen
        default: return nil
        }
    }

    // MARK: Parsing

    /// Recursive-descent evaluator for the token stream. Grammar:
    ///
    ///     expression := term (("+" | "-") term)*
    ///     term       := factor (("*" | "/") factor)*
    ///     factor     := ("+" | "-") factor | number
    ///                 | function "(" expression ")" | "(" expression ")"
    ///
    /// `sawComputation` distinguishes real arithmetic (`2+2`) from a bare
    /// number (`42`), a lone group (`(5)`), or a bare sign (`-5`): without a
    /// binary operator or function call there is nothing to compute.
    private struct Parser {
        let tokens: [Token]
        var position = 0
        var sawComputation = false

        /// Single-argument functions the evaluator implements directly —
        /// in lockstep with `knownFunctions`: a name recognized at the
        /// charset gate must produce a value here.
        static let functions: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() },
            "log": { log10($0) },
            "ln": { log($0) },
            "exp": { exp($0) },
            "abs": { abs($0) },
        ]

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while position < tokens.count, tokens[position] == .plus || tokens[position] == .minus {
                let subtract = tokens[position] == .minus
                sawComputation = true
                position += 1
                guard let rhs = parseTerm() else { return nil }
                value = subtract ? value - rhs : value + rhs
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while position < tokens.count, tokens[position] == .star || tokens[position] == .slash {
                let divide = tokens[position] == .slash
                sawComputation = true
                position += 1
                guard let rhs = parseFactor() else { return nil }
                value = divide ? value / rhs : value * rhs
            }
            return value
        }

        mutating func parseFactor() -> Double? {
            guard position < tokens.count else { return nil }
            switch tokens[position] {
            case .plus:
                position += 1
                return parseFactor()
            case .minus:
                position += 1
                return parseFactor().map { -$0 }
            case .number(let value):
                position += 1
                return value
            case .function(let name):
                guard let function = Self.functions[name] else { return nil }
                position += 1
                guard consume(.leftParen), let argument = parseExpression(), consume(.rightParen) else {
                    return nil
                }
                sawComputation = true
                return function(argument)
            case .leftParen:
                position += 1
                guard let value = parseExpression(), consume(.rightParen) else { return nil }
                return value
            default:
                return nil
            }
        }

        mutating func consume(_ token: Token) -> Bool {
            guard position < tokens.count, tokens[position] == token else { return false }
            position += 1
            return true
        }
    }

    private static func parse(_ tokens: [Token]) -> Double? {
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseExpression(),
              parser.position == tokens.count, parser.sawComputation else { return nil }
        return value
    }

    /// Display string for a result, or `nil` for non-finite values: `1/0` and
    /// `0/0` offer no row rather than `inf`. Integral values print without a
    /// fraction; anything else uses `%g` under a fixed locale so the decimal
    /// separator is always `.` regardless of the user's region.
    private static func displayString(for value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value.truncatingRemainder(dividingBy: 1) == 0, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
