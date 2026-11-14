// Incremental Server-Sent Events parser for the chat-completions and Anthropic Messages streams (ported from Dblore's
// `AISSEParser`, text only: tool calls, the Responses wire and native Gemini are gone). It takes the raw bytes as
// they arrive, so an event split across network chunks, a CRLF split between two chunks and a UTF-8 character split
// in the middle are all reassembled here, where tests can reach them without a network.
import Foundation

public enum AIStreamDelta: Equatable, Sendable {
    /// A piece of the model's answer text.
    case text(String)
    /// The provider ended the stream (`data: [DONE]` or Anthropic's `message_stop`).
    case done
}

public enum AIStreamError: Error, Equatable, Sendable, CustomStringConvertible {
    /// An error event the provider sent in the stream; the text is the provider's message.
    case provider(String)
    /// One line went past `AISSEParser.maxLineBytes` without a line break.
    case lineTooLong

    public var description: String {
        switch self {
        case .provider(let message): message
        case .lineTooLong: "The provider sent an oversized stream line."
        }
    }
}

/// Feed the response bytes with `consume(_:)` and call `finish()` at the end of the body. Lines end with LF, CRLF or
/// a lone CR (the SSE spec allows all three); a blank line dispatches the buffered event; `:` lines are comments
/// (keepalives) and are skipped.
public struct AISSEParser: Sendable {
    /// The longest line buffered. A real event line is a few KB; this bounds the memory a broken or hostile server
    /// can make the client hold by never sending a line break.
    public static let maxLineBytes = 1 << 20

    private let wire: AIWire
    private var line: [UInt8] = []
    /// The last byte was a CR, so an LF right after it (maybe in the next chunk) ends no second line.
    private var afterCR = false
    private var eventName: String?
    private var dataLines: [String] = []

    public init(wire: AIWire) {
        self.wire = wire
    }

    /// Consumes the next bytes of the body and returns the deltas of every event they complete.
    public mutating func consume(_ chunk: some Sequence<UInt8>) throws(AIStreamError) -> [AIStreamDelta] {
        var out: [AIStreamDelta] = []
        for byte in chunk {
            switch byte {
            case 0x0A:
                if afterCR {
                    afterCR = false
                    continue
                }
                out += try endLine()
            case 0x0D:
                afterCR = true
                out += try endLine()
            default:
                afterCR = false
                guard line.count < Self.maxLineBytes else { throw .lineTooLong }
                line.append(byte)
            }
        }
        return out
    }

    /// The body ended: an unterminated last line and an event without its blank line are still dispatched.
    public mutating func finish() throws(AIStreamError) -> [AIStreamDelta] {
        var out: [AIStreamDelta] = []
        if !line.isEmpty { out += try endLine() }
        out += try dispatch()
        return out
    }

    /// Decodes the buffered line only once it is whole, so a multi-byte character split across chunks is intact.
    private mutating func endLine() throws(AIStreamError) -> [AIStreamDelta] {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return try consume(line: text)
    }

    private mutating func consume(line: String) throws(AIStreamError) -> [AIStreamDelta] {
        if line.isEmpty { return try dispatch() }
        if line.hasPrefix(":") { return [] }

        let name: String
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = String(line[..<colon])
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            name = line
            value = ""
        }
        switch name {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return []
    }

    private mutating func dispatch() throws(AIStreamError) -> [AIStreamDelta] {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.joined(separator: "\n")
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return [.done] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return []
        }
        switch wire {
        case .chatCompletions: return try chatDeltas(object)
        case .anthropicMessages: return try anthropicDeltas(object)
        }
    }

    /// Only the first choice's `delta.content` is read. A `choices: []` chunk (the usage chunk of
    /// `stream_options.include_usage`) and reasoning deltas yield nothing.
    private func chatDeltas(_ object: [String: Any]) throws(AIStreamError) -> [AIStreamDelta] {
        if let message = Self.errorMessage(object) { throw .provider(message) }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
            let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String,
            !content.isEmpty
        else { return [] }
        return [.text(content)]
    }

    /// Only `text_delta` pieces are text; thinking deltas, pings and the other block events yield nothing.
    private func anthropicDeltas(_ object: [String: Any]) throws(AIStreamError) -> [AIStreamDelta] {
        switch (object["type"] as? String) ?? eventName {
        case "error":
            throw .provider(Self.errorMessage(object) ?? "The provider returned an error.")
        case "message_stop":
            return [.done]
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String, !text.isEmpty
            else { return [] }
            return [.text(text)]
        default:
            return []
        }
    }

    /// The whole message: the client scrubs the key from it before shortening it, so a cut never leaves part of a
    /// key behind.
    private static func errorMessage(_ object: [String: Any]) -> String? {
        if let text = object["error"] as? String, !text.isEmpty { return text }
        return (object["error"] as? [String: Any])?["message"] as? String
    }
}
