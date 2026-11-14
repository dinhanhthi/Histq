// Security and contract tests for the AI endpoints and the chat client (task 12.1), served by the stub `URLProtocol`
// of `GitHubClientTests`: no test reaches the network. They guard the API key: it only travels in a header to the
// provider's own host, never over plain http to another machine, never through a redirect to another origin, and no
// error shows it.
import Foundation
import HistqCore
import Testing

struct AIEndpointTests {
    /// A made-up key; the tests look for it where it must never be.
    static let key = "sk-HistqFakeKey0123456789"

    static let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: [DONE]


        """

    /// Every text piece of the client's stream, joined.
    static func collect(_ client: AIChatClient) async throws -> String {
        let request = AIChatRequest(model: "m-1", system: "Be brief.", messages: [AIChatMessage(role: .user, text: "Hi")])
        var text = ""
        for try await piece in client.stream(request) { text += piece }
        return text
    }

    // MARK: - Base URL validation

    @Test("plain http to another machine and credentials in the URL are refused", arguments: [
        ("http://api.example.com/v1", AIEndpointError.insecureRemoteHTTP),
        ("http://10.0.0.1:8080/v1", .insecureRemoteHTTP),
        ("http://192.168.1.20/v1", .insecureRemoteHTTP),
        ("http://127.0.0.1.example.com/v1", .insecureRemoteHTTP),
        ("http://localhost.example.com/v1", .insecureRemoteHTTP),
        ("https://user:pass@api.example.com/v1", .credentialsNotAllowed),
        ("https://user@api.example.com/v1", .credentialsNotAllowed),
        ("http://localhost@api.example.com/v1", .credentialsNotAllowed),
        ("ftp://api.example.com/v1", .unsupportedScheme),
        ("   ", .empty),
    ])
    func refusesUnsafeBaseURLs(raw: String, expected: AIEndpointError) {
        #expect(throws: expected) { try AIEndpoint.normalize(raw) }
    }

    @Test("http is allowed for this Mac only, and pasted endpoint suffixes are stripped", arguments: [
        ("http://localhost:11434", "http://localhost:11434/v1"),
        ("http://127.0.0.1:1234/v1/", "http://127.0.0.1:1234/v1"),
        ("http://127.5.6.7/v1/models", "http://127.5.6.7/v1"),
        ("http://[::1]:8080/v1/chat/completions", "http://[::1]:8080/v1"),
        ("HTTPS://api.openai.com/v1/chat/completions?x=1#top", "https://api.openai.com/v1"),
        ("https://api.anthropic.com/v1/messages/", "https://api.anthropic.com/v1"),
        ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
         "https://generativelanguage.googleapis.com/v1beta/openai"),
        ("https://openrouter.ai/api/v1/models", "https://openrouter.ai/api/v1"),
        (" https://api.x.ai ", "https://api.x.ai/v1"),
    ])
    func normalizesBaseURLs(raw: String, expected: String) throws {
        #expect(try AIEndpoint.normalize(raw).absoluteString == expected)
    }

    // MARK: - Requests

    @Test("each provider streams from its own chat URL with the key only in its header", arguments: [
        (AIProvider.openAI, "https://api.openai.com/v1/chat/completions", "Authorization"),
        (.anthropic, "https://api.anthropic.com/v1/messages", "x-api-key"),
        (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "Authorization"),
        (.xAI, "https://api.x.ai/v1/chat/completions", "Authorization"),
        (.custom, "http://localhost:11434/v1/chat/completions", "Authorization"),
    ])
    func providerRequests(provider: AIProvider, url: String, keyHeader: String) async throws {
        let sse = provider == .anthropic
            ? "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            : Self.sse
        let stub = StubServer { _ in .init(headers: ["Content-Type": "text/event-stream"], body: sse) }
        // A custom URL given to a built-in provider is ignored, so its key cannot be sent there.
        let client = try AIChatClient(
            provider: provider, apiKey: Self.key, customBaseURL: provider == .custom ? "http://localhost:11434" : "https://evil.example",
            session: stub.session)

        #expect(try await Self.collect(client) == "Hello")
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.url?.absoluteString == url)
        #expect(request.httpMethod == "POST")
        let expectedHeader = keyHeader == "Authorization" ? "Bearer \(Self.key)" : Self.key
        #expect(request.value(forHTTPHeaderField: keyHeader) == expectedHeader)
        #expect(request.url?.absoluteString.contains(Self.key) == false)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains(Self.key))
        #expect(body.contains("\"stream\":true"))
        #expect(!"\(client)".contains(Self.key) && !String(reflecting: client).contains(Self.key))
    }

    @Test("a key with whitespace or control characters is refused, and a built-in provider needs one")
    func refusesUnusableKeys() {
        #expect(throws: AIClientError.invalidAPIKey) { try AIChatClient(provider: .openAI, apiKey: "sk-a\r\nX-Evil: 1") }
        #expect(throws: AIClientError.missingAPIKey) { try AIChatClient(provider: .anthropic, apiKey: "  ") }
        #expect(throws: AIClientError.invalidEndpoint(.insecureRemoteHTTP)) {
            try AIChatClient(provider: .custom, apiKey: nil, customBaseURL: "http://lan-box.example:8080")
        }
    }

    // MARK: - Redirects and errors

    @Test("a redirect to another host or to plain http is not followed (one on the same origin is)", arguments: [
        ("https://api.openai.com/v1/moved", true),
        ("https://evil.example/v1/chat/completions", false),
        ("http://api.openai.com/v1/moved", false),
    ])
    func redirectGuard(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/v1/chat/completions" {
                return .init(status: 307, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(headers: ["Content-Type": "text/event-stream"], body: Self.sse)
        }
        let client = try AIChatClient(provider: .openAI, apiKey: Self.key, session: stub.session)

        if isFollowed {
            #expect(try await Self.collect(client) == "Hello", "positive control: the stub redirects")
            #expect(stub.requests.count == 2)
        } else {
            let error = await #expect(throws: AIClientError.self) { try await Self.collect(client) }
            #expect(error == .http(status: 307, message: ""))
            #expect(stub.requests.count == 1)
        }
        #expect(stub.requests.allSatisfy { $0.url?.host() == "api.openai.com" && $0.url?.scheme == "https" })
    }

    @Test("an error answer that echoes the key is shown without it")
    func errorsNeverShowTheKey() async throws {
        let stub = StubServer { _ in
            .init(status: 401, body: #"{"error": {"message": "Incorrect API key provided: \#(Self.key). Check it."}}"#)
        }
        let client = try AIChatClient(provider: .custom, apiKey: Self.key, customBaseURL: "https://llm.example", session: stub.session)

        let error = await #expect(throws: AIClientError.self) { try await Self.collect(client) }
        #expect(error == .http(status: 401, message: "Incorrect API key provided: [API key]. Check it."))
        #expect(error?.description.contains(Self.key) == false)
    }
}
