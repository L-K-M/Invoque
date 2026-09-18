import Foundation

/// Which provider protocol `LLMClient` speaks. `openAICompatible` covers
/// OpenAI, OpenRouter, Ollama and LM Studio — all expose the same
/// `/chat/completions` shape; `anthropic` uses the Messages API.
enum LLMProvider: String, CaseIterable {
    case openAICompatible
    case anthropic

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
    }

    /// Whether an API key is mandatory. Local OpenAI-compatible servers
    /// (Ollama, LM Studio) accept unauthenticated requests — the key is
    /// optional there; Anthropic always requires one.
    var requiresAPIKey: Bool { self == .anthropic }
}

/// One turn of the conversation sent to the model. The Maker's feedback loop
/// is just more of these appended to the transcript.
struct LLMMessage: Equatable {
    enum Role: String {
        case system, user, assistant
    }

    let role: Role
    let content: String

    init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// The seam `MakerModel` generates against — the real client talks HTTP, the
/// tests return canned responses. `model` is read for the manifest's
/// `generated.model` provenance.
protocol LLMClientServing {
    var model: String { get }
    func complete(messages: [LLMMessage]) async throws -> String
}

/// `URLRequest` → `(Data, URLResponse)`, so tests can stub the network
/// without `URLProtocol` plumbing. `URLSession` already has this method.
protocol LLMTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: LLMTransport {}

/// Every way a generation request can fail, mapped to readable messages.
enum LLMError: Error, Equatable, LocalizedError {
    /// No API key in Keychain — the user must set one in Settings first.
    case missingAPIKey
    /// `baseURL` could not be turned into a request URL.
    case invalidBaseURL(String)
    /// Non-2xx response; the associated string is a truncated response body.
    case httpError(statusCode: Int, body: String)
    /// Transport-level failure (offline, DNS, TLS, timeout…).
    case transport(String)
    /// A 2xx response whose body didn't match the expected shape.
    case malformedResponse
    /// 2xx, but the model hit its output-token cap — the text is truncated.
    case truncatedOutput(limit: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "no API key configured — add one in Settings → Maker"
        case .invalidBaseURL(let base):
            return "invalid base URL '\(base)'"
        case .httpError(let code, let body):
            return "HTTP \(code) from provider\(body.isEmpty ? "" : ": \(body)")"
        case .transport(let message):
            return message
        case .malformedResponse:
            return "the provider returned a response in an unexpected shape"
        case .truncatedOutput(let limit):
            let cap = limit > 0 ? "the \(limit)-token output cap"
                                : "the provider's output-token cap"
            return "generation stopped at \(cap) — the result was truncated"
        }
    }
}

/// OpenAI-compatible (+ Anthropic) chat client used by the Maker.
///
/// Single-shot, not streaming: a generated command is only useful once both
/// files have fully arrived, so v1 awaits the whole response. The transport
/// is injectable (`LLMTransport`) so tests stub the network without
/// `URLProtocol`.
final class LLMClient: LLMClientServing {

    /// A snapshot of `MakerSettings` at generation time.
    struct Configuration: Equatable {
        var provider: LLMProvider
        var baseURL: String
        var model: String
        var apiKey: String
    }

    var model: String { configuration.model }

    private let configuration: Configuration
    private let transport: LLMTransport

    /// The floor for one generation's total budget. The client is
    /// non-streaming: nothing arrives until the model finishes, so
    /// URLSession's idle timer (`timeoutIntervalForRequest`) is the
    /// effective cap — `defaultTransport` gives it the full budget rather
    /// than the 60 s default, for long generations on slow local models.
    static let requestTimeout: TimeInterval = 60

    /// The full per-request budget, applied to both the session
    /// configuration and each `URLRequest` — a request built with the
    /// plain initializer defaults to 60 s and that value wins over the
    /// session's, so the session-level setting alone would be dead code.
    static var generationBudget: TimeInterval {
        max(requestTimeout * 2, 300)
    }

    init(configuration: Configuration, transport: LLMTransport = LLMClient.defaultTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Ephemeral session — not `.shared`, which would pin the timeout for
    /// every other caller. Both timers get the full budget: in a
    /// non-streaming request the idle timer only fires while the provider
    /// is still working, and that's exactly the wait we're allowing.
    private static func defaultTransport() -> LLMTransport {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = generationBudget
        config.timeoutIntervalForResource = generationBudget
        return URLSession(configuration: config)
    }

    // MARK: Generation

    /// Sends the transcript and returns the model's text output.
    func complete(messages: [LLMMessage]) async throws -> String {
        switch configuration.provider {
        case .openAICompatible:
            return try await completeOpenAI(messages: messages)
        case .anthropic:
            return try await completeAnthropic(messages: messages)
        }
    }

    // MARK: Connection test

    /// Cheap probe used by Settings' "Test connection" button:
    /// `GET {base}/models` for OpenAI-compatible APIs, `GET {base}/v1/models`
    /// for Anthropic. Returns a short human-readable status on success.
    func testConnection() async throws -> String {
        if configuration.provider.requiresAPIKey,
           configuration.apiKey.isEmpty { throw LLMError.missingAPIKey }
        let url = configuration.provider == .anthropic
            ? try anthropicEndpoint("models") : try endpoint("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // A probe should fail fast — an unreachable host otherwise spins
        // for the full generation budget under the Settings button.
        request.timeoutInterval = 15
        applyAuth(to: &request)
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let count = (try? JSONSerialization.jsonObject(with: data))
            .flatMap({ ($0 as? [String: Any])?["data"] as? [Any] })?.count {
            return "OK — \(count) models reachable"
        }
        return "OK — HTTP \(status)"
    }

    // MARK: OpenAI-compatible

    /// `POST {base}/chat/completions` with Bearer auth; the transcript maps
    /// directly onto `messages` (system stays a message here, unlike
    /// Anthropic which wants it top-level).
    private func completeOpenAI(messages: [LLMMessage]) async throws -> String {
        // No key guard here: Ollama/LM Studio and friends are keyless —
        // the Authorization header is simply skipped when none is set.
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        let (data, _) = try await post(body, to: endpoint("chat/completions"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.malformedResponse
        }
        // Same truncation trap as Anthropic: finish_reason "length" means
        // the model hit its output cap and the text is incomplete.
        if (choices.first?["finish_reason"] as? String) == "length" {
            throw LLMError.truncatedOutput(limit: 0)
        }
        return content
    }

    // MARK: Anthropic

    /// `POST {base}/v1/messages`. Differences from the OpenAI shape: auth is
    /// `x-api-key` + `anthropic-version`, `system` is a top-level field rather
    /// than a message, `max_tokens` is required, and the reply text lives in
    /// `content[].text`.
    private func completeAnthropic(messages: [LLMMessage]) async throws -> String {
        guard !configuration.apiKey.isEmpty else { throw LLMError.missingAPIKey }
        let system = messages.filter { $0.role == .system }.map(\.content)
            .joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": configuration.model,
            // The Claude 3 family rejects anything above its 4096 output
            // cap with a 400 — 4096 is valid for every Anthropic model and
            // comfortably covers a command.json + main.js generation.
            "max_tokens": 4096,
            "messages": turns,
        ]
        if !system.isEmpty { body["system"] = system }
        let (data, _) = try await post(body, to: anthropicEndpoint("messages"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else {
            throw LLMError.malformedResponse
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.malformedResponse }
        // A 200 is not success when the cap cut the output: the text ends
        // mid-file and fails far downstream as a confusing parse error.
        if (object["stop_reason"] as? String) == "max_tokens" {
            throw LLMError.truncatedOutput(limit: body["max_tokens"] as? Int ?? 0)
        }
        return text
    }

    // MARK: Plumbing

    /// Anthropic paths carry the API version (`v1/messages`). A base URL
    /// that already ends in `/v1` — common when users copy the OpenAI
    /// shape — must not produce `/v1/v1/messages`.
    private func anthropicEndpoint(_ resource: String) throws -> URL {
        let trimmed = configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let versioned = trimmed.hasSuffix("/v1") || trimmed.hasSuffix("/v1/")
        return try endpoint(versioned ? resource : "v1/\(resource)")
    }

    /// `baseURL` (trailing slashes stripped) + "/" + `path`, as a URL.
    /// Requires an http(s) scheme — a schemeless or `file://` base is a
    /// configuration error worth reporting plainly.
    private func endpoint(_ path: String) throws -> URL {
        var base = configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + path),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw LLMError.invalidBaseURL(configuration.baseURL)
        }
        return url
    }

    /// The one header difference between providers.
    private func applyAuth(to request: inout URLRequest) {
        switch configuration.provider {
        case .openAICompatible:
            // Keyless local servers (Ollama, LM Studio) send no header.
            if !configuration.apiKey.isEmpty {
                request.setValue("Bearer \(configuration.apiKey)",
                                 forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    /// POST a JSON body and validate the HTTP status. The first 300 chars of
    /// a failing body ride along in the error — providers put the real
    /// message there ("invalid api key", "model not found").
    private func post(_ body: [String: Any], to url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // URLRequest's own 60 s default overrides the session
        // configuration for data tasks — the budget must land here too.
        request.timeoutInterval = Self.generationBudget
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as CancellationError {
            // Cancellation is the Maker discarding mid-flight — pass it
            // through unwrapped so `runGeneration` recognizes it.
            throw error
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports task cancellation as URLError(.cancelled).
            throw CancellationError()
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(statusCode: http.statusCode,
                                     body: String(body.prefix(300)))
        }
        return (data, response)
    }
}
