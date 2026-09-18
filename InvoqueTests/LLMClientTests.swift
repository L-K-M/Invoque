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

    private func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
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
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer sk-test")
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
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "sk-test")
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
        }
    }

    func testMissingAPIKeyThrowsBeforeNetwork() async {
        let transport = StubTransport()
        let client = makeClient(transport: transport, apiKey: "")

        do {
            _ = try await client.complete(messages: [LLMMessage(.user, "hi")])
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LLMError, .missingAPIKey)
        }
        XCTAssertNil(transport.request)  // never hit the wire
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
}
