#if DEBUG
// DEBUG `-HistqAIStub YES|error` (state-dir runs only): the AI flows without a provider. `AISetup.makeClient` then uses
// a `URLSession` whose only protocol is `AIStubProtocol`, which answers every request itself and never passes one on
// to the network: a canned SSE stream in the request's wire format (Anthropic Messages for `/messages`, chat
// completions otherwise), sent in small chunks over about a second so the preview streams and Cancel can stop it. The
// answer carries the prompt's own boundary token (read from the request's system prompt): a commit message, an
// explanation, or for a resolution side A's text then side B's with LF line breaks; a request without one (Test
// connection) gets "OK". `error` answers HTTP 401 instead. With `-HistqKeychain memory`, every built-in provider gets a
// fake key in the in-memory Keychain, so the AI buttons are enabled.
//
// `-HistqAI <hook>[,apply][,cancel]` (stub runs only) clicks one AI button once it can run: `generate` (commit box),
// `explain-wip` (commit box), `explain` (commit details), `resolve` (conflict editor), `test` (Settings › AI, Test
// Connection); `apply` applies the finished answer, `cancel` cancels as soon as the first words show, `close-tab` and
// `close-window` close the card's tab or window while the job still reads its content. Evidence goes to
// `<stateDir>/ai.log` (never a key).
import Foundation
import HistqCore
import os

enum AIStub {
    /// "YES" or "error"; nil when the stub is off.
    static let mode: String? = {
        guard AppState.isStateDirMode, let value = AppState.launchFlag("-HistqAIStub"),
              value == "YES" || value == "error"
        else { return nil }
        return value
    }()

    static var isEnabled: Bool { mode != nil }

    /// Never a real key: nothing leaves the stub session.
    static let fakeKey = "histq_ai_stub_fake_key"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStubProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Saves the fake key for every built-in provider, once, only in the in-memory Keychain of a state-dir run.
    @concurrent
    static func seedKeysIfNeeded() async {
        guard isEnabled, KeychainStore.shared.isInMemory, AppState.isStateDirMode else { return }
        guard seeded.withLock({ done in defer { done = true }; return !done }) else { return }
        for provider in AIProvider.allCases where provider.requiresAPIKey {
            try? await AIKeys.save(fakeKey, for: provider)
        }
        log("seeded fake keys (memory keychain)")
    }

    private static let seeded = OSAllocatedUnfairLock(initialState: false)

    // MARK: Seams

    /// The `-HistqAI` hook and its options.
    private static let seamParts: [String] = isEnabled
        ? (AppState.launchFlag("-HistqAI") ?? "").split(separator: ",").map(String.init) : []
    static var seamOptions: Set<String> { Set(seamParts.dropFirst()) }

    @MainActor private static var seamTaken = false

    /// True once, for the hook `-HistqAI` names.
    @MainActor
    static func takeSeam(_ hook: String) -> Bool {
        guard !seamTaken, seamParts.first == hook else { return false }
        seamTaken = true
        log("click \(hook)")
        return true
    }

    // MARK: Log

    private static let queue = DispatchQueue(label: "com.math2it.histq.ai-stub-log")

    /// Appends a line to `<stateDir>/ai.log`. Callers never pass a key.
    static func log(_ line: String) {
        guard let directory = AppState.stateDirectory else { return }
        let path = directory.appending(path: "ai.log").path
        let stamped = "\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000) \(line)\n"
        queue.async {
            guard let handle = FileHandle(forWritingAtPath: path) ?? {
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }() else { return }
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        }
    }

    /// `text` on one line, its line breaks escaped, in quotes.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // MARK: Replies

    /// The whole reply text for a request body.
    static func replyText(body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "OK" }
        let messages = object["messages"] as? [[String: Any]] ?? []
        let system = object["system"] as? String
            ?? messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
        let user = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        guard let range = system.range(of: "BEGIN ANSWER histq-[0-9a-f]+", options: .regularExpression) else {
            return "OK"
        }
        let token = String(system[range].dropFirst("BEGIN ANSWER ".count))
        let answer: String
        if system.contains("Write a git commit message") {
            answer = "Add a canned change from the AI stub\n\nWritten by the DEBUG AI stub (-HistqAIStub); no "
                + "provider was called.\n"
        } else if system.contains("Resolve one git merge conflict") {
            // LF only, as models usually answer: Apply must convert it to a CRLF file's line breaks.
            answer = (terminated(block(in: user, token: token, label: "A: ours"))
                + terminated(block(in: user, token: token, label: "B: theirs")))
                .replacingOccurrences(of: "\r\n", with: "\n")
        } else {
            answer = "This change was explained by the **DEBUG AI stub**.\n\n- No provider was called.\n- The "
                + "prompt held \(user.utf8.count) bytes.\n"
        }
        return "Here is the answer.\nBEGIN ANSWER \(token)\n\(terminated(answer))END ANSWER \(token)\n"
    }

    private static func terminated(_ text: String) -> String {
        text.isEmpty || text.utf8.last == 0x0A ? text : text + "\n"
    }

    /// The content of the data block whose label starts with `label`.
    private static func block(in user: String, token: String, label: String) -> String {
        guard let header = user.range(of: "BEGIN DATA \(token) (\(label)"),
              let lineEnd = user[header.upperBound...].firstIndex(of: "\n"),
              let end = user[lineEnd...].range(of: "END DATA \(token)")
        else { return "" }
        return String(user[user.index(after: lineEnd)..<end.lowerBound])
    }

    /// `text` as an SSE body of `wire`, in pieces of a few characters.
    static func sse(_ text: String, wire: AIWire) -> String {
        var pieces: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            pieces.append(String(rest.prefix(12)))
            rest = rest.dropFirst(12)
        }
        var body = ""
        for piece in pieces {
            switch wire {
            case .chatCompletions:
                body += "data: " + json(["choices": [["index": 0, "delta": ["content": piece]]]]) + "\n\n"
            case .anthropicMessages:
                body += "event: content_block_delta\ndata: "
                    + json(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": piece]])
                    + "\n\n"
            }
        }
        switch wire {
        case .chatCompletions: body += "data: [DONE]\n\n"
        case .anthropicMessages: body += "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        }
        return body
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Answers every request of `AIStub.session` itself: never passes one on to the network. The chunks go out from a
/// timer on the loading thread's run loop (the thread URLProtocol calls must come from), so `stopLoading` (a cancel)
/// stops them.
final class AIStubProtocol: URLProtocol, @unchecked Sendable {
    private var chunks: [Data] = []
    private var sent = 0
    private var timer: Timer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let hasKey = request.value(forHTTPHeaderField: "Authorization") != nil
            || request.value(forHTTPHeaderField: "x-api-key") != nil
        AIStub.log("stub request \(request.httpMethod ?? "") \(url.host() ?? "")\(url.path()) key-header "
            + "\(hasKey ? "present" : "none") body-bytes \(body.count)")
        if AIStub.mode == "error" {
            respond(url, status: 401, type: "application/json")
            client?.urlProtocol(self, didLoad: Data(#"{"error": {"message": "Incorrect API key provided (stub)."}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let wire: AIWire = url.path().hasSuffix("/messages") ? .anthropicMessages : .chatCompletions
        let stream = Data(AIStub.sse(AIStub.replyText(body: body), wire: wire).utf8)
        // Cut anywhere, events included: the client's parser must join them.
        let size = max(1, stream.count / 12 + 1)
        chunks = stride(from: 0, to: stream.count, by: size).map { stream.subdata(in: $0..<min($0 + size, stream.count)) }
        respond(url, status: 200, type: "text/event-stream")
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.sendNext()
        }
        self.timer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    override func stopLoading() {
        timer?.invalidate()
        timer = nil
        if sent < chunks.count {
            AIStub.log("stub stopLoading after \(sent)/\(chunks.count) chunks")
        }
    }

    private func sendNext() {
        guard sent < chunks.count else { return }
        client?.urlProtocol(self, didLoad: chunks[sent])
        sent += 1
        if sent == chunks.count {
            timer?.invalidate()
            timer = nil
            AIStub.log("stub finished \(chunks.count) chunks")
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func respond(_ url: URL, status: Int, type: String) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": type])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    /// A request's body: URLSession hands it to the protocol as a stream.
    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
