import Foundation

/// Offers one `= result` row with a copy action when the query is arithmetic,
/// e.g. `2+2` offers `= 4`.
///
/// Safety: `NSExpression.expressionValue` raises an Objective-C exception on
/// input it cannot evaluate, and Swift cannot catch Objective-C exceptions:
/// that would be a crash, not an error. So nothing reaches `NSExpression`
/// unproven. Every query passes three gates: a mathy-shape prefilter, a
/// character allowlist, and a full recursive-descent parse. Shell text,
/// unknown identifiers, multi-argument calls, and unbalanced parens are never
/// evaluated.
final class CalculatorSource: ItemSource {

    // MARK: ItemSource

    /// Zero or one item: the evaluated result, or nothing when the query is
    /// not well-formed arithmetic.
    func items(matching query: String) -> [Item] {
        guard let evaluation = Self.evaluate(query) else { return [] }
        return [Item(
            id: Item.calculatorIDPrefix + evaluation.expression,
            title: "= \(evaluation.result)",
            subtitle: "Copy result to clipboard",
            icon: .symbol("equal.square"),
            action: .copyText(evaluation.result),
            matchText: "\(evaluation.expression) = \(evaluation.result)"
        )]
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
        guard let tokens = tokenize(expression), parsesAsComputation(tokens) else { return nil }
        guard let value = evaluateWithNSExpression(expression) else { return nil }
        guard let display = displayString(for: value) else { return nil }
        return Evaluation(expression: expression, result: display)
    }

    // MARK: Gates

    /// Cap on evaluated length: deep paren nesting is a parse-time and
    /// stack-depth hazard with no legitimate launcher use.
    private static let maxExpressionLength = 200

    /// Cheap prefilter so plain words skip tokenizing: the query must open
    /// with a digit, an opening paren, or a sign. Notably, a leading function
    /// name (`sqrt(9)`) does not pass; functions only count mid-expression
    /// (`2+sqrt(9)`).
    private static func looksMathy(_ expression: String) -> Bool {
        guard !expression.isEmpty, expression.count <= Self.maxExpressionLength else { return false }
        guard let first = expression.first else { return false }
        return "0123456789(+-".contains(first)
    }

    /// Every letter run must be a known function name; every other character
    /// must be plain math punctuation. Anything else (shell operators,
    /// quotes, `$()`, stray words like `rm`) is rejected here.
    private static let knownFunctions: Set<String> = [
        "sqrt", "pow", "log", "ln", "exp", "abs", "sin", "cos", "tan", "mod",
    ]

    /// Digits, decimal point, the four basic operators, parens, comma, and
    /// spaces. `%` passes this gate (it reads as math) but is declined while
    /// tokenizing: `NSExpression`'s format grammar does not document it, and
    /// offering no row beats risking an Objective-C exception.
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

    /// Recursive-descent proof that the tokens form one well-formed
    /// expression. Grammar:
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

        /// Functions `NSExpression` evaluates with one argument. Other known
        /// names (`sin`, `pow`, `mod`, ...) pass the charset gate but are
        /// declined here: an unknown selector raises an Objective-C exception
        /// at eval time, which Swift cannot catch.
        static let evaluableFunctions: Set<String> = ["sqrt", "log", "ln", "exp", "abs"]

        mutating func parseExpression() -> Bool {
            guard parseTerm() else { return false }
            while position < tokens.count, tokens[position] == .plus || tokens[position] == .minus {
                sawComputation = true
                position += 1
                guard parseTerm() else { return false }
            }
            return true
        }

        mutating func parseTerm() -> Bool {
            guard parseFactor() else { return false }
            while position < tokens.count, tokens[position] == .star || tokens[position] == .slash {
                sawComputation = true
                position += 1
                guard parseFactor() else { return false }
            }
            return true
        }

        mutating func parseFactor() -> Bool {
            guard position < tokens.count else { return false }
            switch tokens[position] {
            case .plus, .minus:
                position += 1
                return parseFactor()
            case .number:
                position += 1
                return true
            case .function(let name):
                guard Self.evaluableFunctions.contains(name) else { return false }
                position += 1
                guard consume(.leftParen), parseExpression(), consume(.rightParen) else { return false }
                sawComputation = true
                return true
            case .leftParen:
                position += 1
                guard parseExpression(), consume(.rightParen) else { return false }
                return true
            default:
                return false
            }
        }

        mutating func consume(_ token: Token) -> Bool {
            guard position < tokens.count, tokens[position] == token else { return false }
            position += 1
            return true
        }
    }

    private static func parsesAsComputation(_ tokens: [Token]) -> Bool {
        var parser = Parser(tokens: tokens)
        return parser.parseExpression() && parser.position == tokens.count && parser.sawComputation
    }

    // MARK: NSExpression

    /// Hands the proven expression to `NSExpression`. Safe by construction:
    /// the input is balanced single-operator arithmetic over known functions,
    /// so neither the format parse nor the evaluation should find anything to
    /// raise about.
    private static func evaluateWithNSExpression(_ expression: String) -> Double? {
        let parsed = NSExpression(format: expression)
        guard let number = parsed.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }
        return number.doubleValue
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
