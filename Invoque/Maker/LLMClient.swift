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

    /// How long one generation request may take. Long generations on a slow
    /// local model can exceed URLSession's 60 s default, so resource timeout
    /// gets headroom while the per-request timeout stays the contract.
    static let requestTimeout: TimeInterval = 60

    init(configuration: Configuration, transport: LLMTransport = LLMClient.defaultTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Ephemeral session with the 60 s request timeout — not `.shared`: the
    /// shared session would pin the timeout for every other caller.
    private static func defaultTransport() -> LLMTransport {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = max(requestTimeout * 2, 300)
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

    /// Cheap authenticated probe used by Settings' "Test connection" button:
    /// `GET {base}/models` for OpenAI-compatible APIs, `GET {base}/v1/models`
    /// for Anthropic. Returns a short human-readable status on success.
    func testConnection() async throws -> String {
        guard !configuration.apiKey.isEmpty else { throw LLMError.missingAPIKey }
        let url = try endpoint(configuration.provider == .anthropic
                               ? "v1/models" : "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
        guard !configuration.apiKey.isEmpty else { throw LLMError.missingAPIKey }
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
        let (data, _) = try await post(body, to: endpoint("v1/messages"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else {
            throw LLMError.malformedResponse
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.malformedResponse }
        return text
    }

    // MARK: Plumbing

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
            request.setValue("Bearer \(configuration.apiKey)",
                             forHTTPHeaderField: "Authorization")
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
