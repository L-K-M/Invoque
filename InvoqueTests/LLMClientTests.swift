import XCTest
@testable import Invoque

final class LLMClientTests: XCTestCase {

    // MARK: Stub transport

    /// Captures the request and returns a canned response — no URLProtocol
    /// plumbing, no real network.
    private final class StubTransport: LLMTransport {
        var request: URLRequest?
        var response: Result<(Data, URLResponse), Error> = .failure(LLMError.malformedResponse)

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.request = request
            return try response.get()
        }
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// A fixture that can't serialize should fail loudly here, not leak
    /// an empty body into the stub and misattribute the failure.
    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeClient(provider: LLMProvider = .openAICompatible,
                            baseURL: String = "https://api.test/v1",
                            transport: StubTransport,
                            apiKey: String = "sk-test") -> LLMClient {
        LLMClient(configuration: LLMClient.Configuration(
            provider: provider,
            baseURL: baseURL,
            model: "test-model",
            apiKey: apiKey),
            transport: transport)
    }

    // MARK: OpenAI-compatible

    func testOpenAIRequestShape() async throws {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["choices": [["message": ["role": "assistant",
                                              "content": "the answer"]]]]),
            httpResponse(status: 200)))
        let client = makeClient(transport: transport)

        let output = try await client.complete(messages: [
            LLMMessage(.system, "sys"), LLMMessage(.user, "hi"),
        ])
        XCTAssertEqual(output, "the answer")

        let request = transport.request
        XCTAssertEqual(request?.url?.absoluteString,
                       "https://api.test/v1/chat/completions")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer sk-test")
        // OpenAI mode must not leak the Anthropic header pair.
        XCTAssertNil(request?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request?.value(forHTTPHeaderField: "anthropic-version"))
        let body = request?.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "test-model")
        let messages = body?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertEqual(messages?.last?["content"], "hi")
    }

    // MARK: Anthropic

    func testAnthropicRequestShape() async throws {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["content": [["type": "text", "text": "the answer"]]]),
            httpResponse(status: 200)))
        // Anthropic's base has no /v1 — the endpoint path carries it.
        let client = makeClient(provider: .anthropic,
                                baseURL: "https://api.anthropic.com",
                                transport: transport)

        let output = try await client.complete(messages: [
            LLMMessage(.system, "sys"), LLMMessage(.user, "hi"),
        ])
        XCTAssertEqual(output, "the answer")

        let request = transport.request
        XCTAssertEqual(request?.url?.absoluteString,
                       "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        // Anthropic mode must not leak the OpenAI-style bearer header.
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-version"),
                       "2023-06-01")
        let body = request?.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } as? [String: Any]
        // System is a top-level field, not a message, on Anthropic.
        XCTAssertEqual(body?["system"] as? String, "sys")
        let messages = body?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"], "user")
        XCTAssertNotNil(body?["max_tokens"])
    }

    // MARK: Errors

    func testHTTPErrorMapsToTypedError() async {
        let transport = StubTransport()
        transport.response = .success((
            Data("bad key".utf8), httpResponse(status: 401)))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch let error as LLMError {
            guard case .httpError(let code, let body) = error else {
                return XCTFail("expected httpError, got \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("bad key"))
        } catch {
            XCTFail("expected LLMError, got \(error)")
        }
    }

    func testMissingAPIKeyThrowsBeforeNetwork() async {
        let transport = StubTransport()
        // Anthropic always requires a key — openAICompatible doesn't
        // (keyless local servers like Ollama).
        let client = makeClient(provider: .anthropic,
                                baseURL: "https://api.anthropic.com",
                                transport: transport, apiKey: "")

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LLMError, .missingAPIKey)
        }
        XCTAssertNil(transport.request)  // never hit the wire
    }

    /// Keyless local servers (Ollama, LM Studio) must work without a key —
    /// no Authorization header, no missingAPIKey error.
    func testKeylessOpenAIProviderSendsNoAuthHeader() async throws {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["choices": [["message": ["content": "hi"],
                                   "finish_reason": "stop"]]]),
            httpResponse(status: 200)))
        let client = makeClient(provider: .openAICompatible,
                                baseURL: "http://localhost:11434/v1",
                                transport: transport, apiKey: "")

        _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
        XCTAssertNil(transport.request?
            .value(forHTTPHeaderField: "Authorization"))
    }

    /// finish_reason "length" on a 200 is truncated output, not success —
    /// the text ends mid-file and must surface as a typed error.
    func testFinishReasonLengthThrowsTruncated() async {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["choices": [["message": ["content": "--- command.json"],
                                   "finish_reason": "length"]]]),
            httpResponse(status: 200)))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch LLMError.truncatedOutput {
            // expected
        } catch {
            XCTFail("expected truncatedOutput, got \(error)")
        }
    }

    /// A 2xx with empty message content (refusal, content_filter) is a
    /// failure, not an empty generation — same guard as Anthropic's path.
    func testEmptyOpenAICompletionThrowsMalformed() async {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["choices": [["message": ["content": ""],
                                   "finish_reason": "content_filter"]]]),
            httpResponse(status: 200)))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch LLMError.malformedResponse {
            // expected
        } catch {
            XCTFail("expected malformedResponse, got \(error)")
        }
    }

    /// Anthropic's equivalent: stop_reason "max_tokens" on a 200.
    func testAnthropicMaxTokensThrowsTruncated() async {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["content": [["text": "partial"]],
                      "stop_reason": "max_tokens"]),
            httpResponse(status: 200)))
        let client = makeClient(provider: .anthropic,
                                baseURL: "https://api.anthropic.com",
                                transport: transport)

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch LLMError.truncatedOutput(let limit) {
            XCTAssertEqual(limit, 4096)
        } catch {
            XCTFail("expected truncatedOutput, got \(error)")
        }
    }

    /// An Anthropic base URL that already ends in /v1 must not double it.
    func testAnthropicBaseWithV1DoesNotDoublePath() async throws {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["content": [["text": "hi"]], "stop_reason": "end_turn"]),
            httpResponse(status: 200)))
        let client = makeClient(provider: .anthropic,
                                baseURL: "https://api.anthropic.com/v1",
                                transport: transport)

        _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
        XCTAssertEqual(transport.request?.url?.absoluteString,
                       "https://api.anthropic.com/v1/messages")
    }

    func testMalformedResponseThrows() async {
        let transport = StubTransport()
        transport.response = .success((
            Data("garbage".utf8), httpResponse(status: 200)))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LLMError, .malformedResponse)
        }
    }

    func testTransportErrorIsWrapped() async {
        let transport = StubTransport()
        transport.response = .failure(URLError(.notConnectedToInternet))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch let error as LLMError {
            guard case .transport = error else {
                return XCTFail("expected transport, got \(error)")
            }
        } catch {
            XCTFail("expected LLMError, got \(error)")
        }
    }

    // MARK: Connection test

    func testTestConnectionHitsModelsEndpoint() async throws {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["data": [["id": "m1"], ["id": "m2"]]]),
            httpResponse(status: 200)))
        let client = makeClient(transport: transport)

        let status = try await client.testConnection()
        XCTAssertTrue(status.contains("OK"))
        XCTAssertEqual(transport.request?.url?.absoluteString,
                       "https://api.test/v1/models")
        XCTAssertEqual(transport.request?.httpMethod, "GET")
    }

    func testTestConnectionHitsAnthropicModelsEndpoint() async throws {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["data": [["id": "claude-sonnet-4-5"]]]),
            httpResponse(status: 200)))
        let client = makeClient(provider: .anthropic,
                                baseURL: "https://api.anthropic.com",
                                transport: transport)

        let status = try await client.testConnection()
        XCTAssertTrue(status.contains("OK"))
        // Anthropic's base has no /v1 — the endpoint path carries it.
        XCTAssertEqual(transport.request?.url?.absoluteString,
                       "https://api.anthropic.com/v1/models")
        XCTAssertEqual(transport.request?.httpMethod, "GET")
        XCTAssertEqual(transport.request?.timeoutInterval, 15)
        XCTAssertEqual(transport.request?
            .value(forHTTPHeaderField: "x-api-key"), "sk-test")
    }

    /// URLRequest's 60 s default would silently override the session's
    /// timeout configuration — generation requests must carry the budget.
    func testGenerationRequestCarriesFullTimeoutBudget() async throws {
        let transport = StubTransport()
        transport.response = .success((
            jsonData(["choices": [["message": ["content": "x"],
                                   "finish_reason": "stop"]]]),
            httpResponse(status: 200)))
        let client = makeClient(transport: transport)

        _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
        XCTAssertEqual(transport.request?.timeoutInterval,
                       LLMClient.generationBudget)
    }
}
