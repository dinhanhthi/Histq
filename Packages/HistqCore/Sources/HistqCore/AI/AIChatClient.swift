// Text-only streaming chat with one cloud provider (ported from Dblore's `AIChatClient`, `AIClientFactory` and
// `AIRedirectGuard`, without tools, model lists, OAuth or local models). The `URLSession` is injected, so tests serve
// inline SSE through a stub `URLProtocol` and never reach the network.
//
// The API key is a secret: it only ever goes in a request header to the provider's own host. A built-in provider
// always uses its fixed base URL and a custom one must pass `AIEndpoint.normalize`; a redirect to another origin is
// not followed (a redirected request would carry the header along); every error is scrubbed of the key, and
// `print`, `dump` and `String(reflecting:)` of a client show only its provider and host.
import Foundation

public struct AIChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct AIChatRequest: Sendable, Equatable {
    public var model: String
    public var system: String
    public var messages: [AIChatMessage]
    /// The answer's token cap. Anthropic requires one; the chat-completions wire only sends it to custom endpoints
    /// (see `AIProviderRequests.chatCompletions`).
    public var maxTokens: Int

    public init(model: String, system: String, messages: [AIChatMessage], maxTokens: Int = 4096) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
    }
}

public enum AIClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingAPIKey
    /// A key with whitespace, control or non-ASCII characters (it would break the header).
    case invalidAPIKey
    case missingModel
    case invalidEndpoint(AIEndpointError)
    /// A non-2xx answer; `message` is the provider's error text, without the key.
    case http(status: Int, message: String)
    /// An error event inside the stream, without the key.
    case provider(String)
    /// A stream the parser refused.
    case invalidResponse(String)
    /// The request did not complete (offline, timeout, TLS).
    case transport(String)

    public var description: String {
        switch self {
        case .missingAPIKey: "Add an API key in Settings > AI."
        case .invalidAPIKey: "The API key has characters a key cannot have."
        case .missingModel: "Choose a model in Settings > AI."
        case .invalidEndpoint(let error): error.description
        case .http(let status, let message):
            message.isEmpty ? "The provider answered HTTP \(status)." : "The provider answered \(status): \(message)"
        case .provider(let message): message
        case .invalidResponse(let detail): "Unexpected answer from the provider: \(detail)"
        case .transport(let detail): "Could not reach the provider: \(detail)"
        }
    }
}

public struct AIChatClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let provider: AIProvider
    /// The normalized base URL every request goes to.
    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    /// Max bytes of an error response body that are read.
    static let errorBodyLimit = 4096
    /// The longest error message kept from a response body.
    static let maxMessageCharacters = 500

    /// `customBaseURL` is used only by `.custom`: a built-in provider always talks to its own `defaultBaseURL`, so its
    /// key can never be sent elsewhere. `apiKey` is trimmed; an empty key is refused unless the provider takes none.
    public init(
        provider: AIProvider, apiKey: String?, customBaseURL: String? = nil, session: URLSession = .shared
    ) throws(AIClientError) {
        let raw = provider == .custom ? customBaseURL ?? "" : provider.defaultBaseURL
        do {
            baseURL = try AIEndpoint.normalize(raw)
        } catch {
            throw .invalidEndpoint(error)
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            if provider.requiresAPIKey { throw .missingAPIKey }
        } else if !Self.isUsableAPIKey(key) {
            throw .invalidAPIKey
        }
        self.provider = provider
        self.apiKey = key
        self.session = session
    }

    /// Printable ASCII without spaces: anything else would break or split the header it goes in.
    public static func isUsableAPIKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    public var description: String {
        "AIChatClient(\(provider.rawValue), \(baseURL.host() ?? ""), key: \(apiKey.isEmpty ? "none" : "set"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider, "baseURL": baseURL]) }

    /// Streams the answer's text pieces. Errors are `AIClientError`s without the key. Cancelling the consuming task
    /// (or dropping the stream) cancels the request.
    public func stream(_ request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        var request = request
        request.model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.model.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: AIClientError.missingModel) }
        }
        let urlRequest = AIProviderRequests.make(request, provider: provider, baseURL: baseURL, apiKey: apiKey)
        return Self.streamLines(urlRequest, session: session, parser: AISSEParser(wire: provider.wire), secret: apiKey)
    }

    /// Streams an SSE response through `parser`, with the redirect guard. Iterates raw bytes and hands them to the
    /// parser in line-sized chunks, because `AsyncBytes.lines` drops the blank lines that dispatch events.
    static func streamLines(
        _ request: URLRequest, session: URLSession, parser: AISSEParser, secret: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request, delegate: AIRedirectGuard())
                    guard let http = response as? HTTPURLResponse else {
                        throw AIClientError.invalidResponse("not HTTP")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        let body = try await collectBody(bytes)
                        throw AIClientError.http(
                            status: http.statusCode, message: scrubbed(errorMessage(from: body), secret: secret))
                    }
                    var parser = parser
                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(4096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        // Hand over at each line end so text reaches the preview as soon as its event is whole.
                        guard byte == 0x0A || byte == 0x0D || chunk.count >= 16_384 else { continue }
                        if yield(try parser.consume(chunk), to: continuation) { return }
                        chunk.removeAll(keepingCapacity: true)
                    }
                    if yield(try parser.consume(chunk) + parser.finish(), to: continuation) { return }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as AIClientError {
                    continuation.finish(throwing: error)
                } catch let error as AIStreamError {
                    switch error {
                    case .provider(let message):
                        continuation.finish(throwing: AIClientError.provider(scrubbed(message, secret: secret)))
                    case .lineTooLong:
                        continuation.finish(throwing: AIClientError.invalidResponse(error.description))
                    }
                } catch let error as URLError {
                    // The URL never holds the key, but the description is scrubbed anyway like every other message.
                    let detail = "\(error.localizedDescription) (URL error \(error.code.rawValue))"
                    continuation.finish(throwing: AIClientError.transport(scrubbed(detail, secret: secret)))
                } catch {
                    continuation.finish(throwing: AIClientError.transport(scrubbed("\(error)", secret: secret)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields the text deltas; returns true when a `.done` delta ended the stream (it is then finished).
    private static func yield(
        _ deltas: [AIStreamDelta], to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> Bool {
        for delta in deltas {
            switch delta {
            case .text(let text):
                continuation.yield(text)
            case .done:
                continuation.finish()
                return true
            }
        }
        return false
    }

    private static func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= errorBodyLimit { break }
        }
        return body
    }

    /// `error.message`, `error` (a string) or `message` of a JSON body, else the raw text.
    static func errorMessage(from body: Data) -> String {
        var message = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let text = error["message"] as? String {
                message = text
            } else if let text = object["error"] as? String {
                message = text
            } else if let text = object["message"] as? String {
                message = text
            }
        }
        return message
    }

    /// `text` with every occurrence of the key replaced, then cut to 500 characters. Providers usually mask a key
    /// they echo, but a custom server may not, and its message is shown in the UI. The key is replaced before the
    /// cut, so a cut through the key never leaves its first part behind.
    static func scrubbed(_ text: String, secret: String) -> String {
        let clean = secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[API key]")
        return String(clean.prefix(maxMessageCharacters))
    }
}

/// Refuses a redirect to another origin (scheme, host or port), so the key header is never forwarded to another
/// host or over a downgraded scheme. The 3xx answer then fails as an HTTP error.
final class AIRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url, GitHubHTTP.isSameOrigin(from, to) else {
            return nil
        }
        return request
    }
}
