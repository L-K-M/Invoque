import Foundation

/// Base conversions are immediate; Numbat answers arrive through a debounced cache.
final class CalculatorSource: ItemSource {
    typealias Evaluator = @Sendable (String) async throws -> String?
    static let debounceNanoseconds: UInt64 = 80_000_000
    private static let maxExpressionLength = 200

    var onReload: (() -> Void)?

    private let evaluator: Evaluator
    private var task: Task<Void, Never>?
    private var activeExpression: String?
    private var answer: Item?

    var isPending: Bool { task != nil }

    init(evaluator: @escaping Evaluator = { try await NumbatEvaluator().evaluate($0) }) {
        self.evaluator = evaluator
    }

    deinit { task?.cancel() }

    // MARK: Query lifecycle (main thread)

    /// Called only for normal search. A cache-driven refresh keeps the same run.
    func update(for query: String) {
        let expression = Self.expression(for: query)
        guard expression != activeExpression else { return }
        cancel()
        guard let expression else { return }
        activeExpression = expression
        let evaluator = evaluator
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                let result = try await evaluator(expression)
                try Task.checkCancellation()
                self?.finish(expression: expression, result: result)
            } catch is CancellationError {
                // An edited query or hidden panel no longer needs this result.
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(expression: expression, failure: error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeExpression = nil
        answer = nil
    }

    private func finish(expression: String, result: String? = nil, failure: String? = nil) {
        guard expression == activeExpression else { return }
        task = nil
        answer = (result ?? failure).map { text in
            Item(id: Item.calculatorIDPrefix + expression,
                 title: failure == nil ? "= \(text)" : "Calculator unavailable",
                 subtitle: failure ?? "Numbat · Copy result to clipboard",
                 icon: .symbol(failure == nil ? "equal.square" : "exclamationmark.triangle"),
                 action: .copyText(text),
                 matchText: "\(expression) = \(text)")
        }
        onReload?()
    }

    // MARK: ItemSource

    /// SearchModel only reads cached answers here; it never launches a process.
    func items(matching query: String) -> [Item] {
        if let conversion = Self.baseConversion(query) { return [conversion] }
        guard Self.expression(for: query) == activeExpression, let answer else { return [] }
        return [answer]
    }

    /// Keep ordinary words and bare numbers as searches. `=` explicitly requests
    /// any Numbat expression, including constants such as `= speed_of_light`.
    static func expression(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxExpressionLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        if trimmed.hasPrefix("=") {
            let expression = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return expression.isEmpty ? nil : expression
        }
        guard parseBaseQuery(trimmed) == nil else { return nil }
        if ["pi", "π", "tau", "τ"].contains(trimmed) { return trimmed }
        // Function calls and numeric quantities cover Numbat's common calculator syntax.
        if let first = trimmed.first, first.isLetter, trimmed.contains("(") { return trimmed }
        guard let first = trimmed.first, "0123456789.(+-−".contains(first),
              trimmed.contains(where: { $0.isLetter || "*/^%!→".contains($0) })
                || trimmed.dropFirst().contains(where: { "+-−".contains($0) }) else { return nil }
        return trimmed
    }

    // MARK: Base conversion

    private static let conversionBases: [(radix: Int, prefix: String, name: String)] = [
        (16, "0x", "Hex"), (2, "0b", "Bin"), (8, "0o", "Oct"),
    ]

    private struct BaseQuery {
        let value: UInt64
        let inputRadix: Int?
    }

    /// Two decimal digits avoid pinning a conversion above a one-digit app query.
    private static func parseBaseQuery(_ trimmed: String) -> BaseQuery? {
        let lowered = trimmed.lowercased()
        for (radix, prefix, _) in conversionBases where lowered.hasPrefix(prefix) {
            let digits = lowered.dropFirst(prefix.count)
            guard !digits.isEmpty,
                  let value = UInt64(digits, radix: radix) else { return nil }
            return BaseQuery(value: value, inputRadix: radix)
        }
        guard trimmed.count >= 2,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(trimmed) else { return nil }
        return BaseQuery(value: value, inputRadix: nil)
    }

    private static func baseConversion(_ query: String) -> Item? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = parseBaseQuery(trimmed) else { return nil }

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
}
