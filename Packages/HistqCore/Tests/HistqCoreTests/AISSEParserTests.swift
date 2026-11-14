// Key feature tests for the SSE parser (task 12.1): the answer text is assembled the same however the network cuts
// the stream into chunks (inside an event, a line, a CRLF or a UTF-8 character), for both wire formats, with CRLF
// line endings, keepalive comments and the end-of-stream event.
import Foundation
import HistqCore
import Testing

struct AISSEParserTests {
    static let chatStream = """
        : keepalive

        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

        data: {"choices":[{"index":0,"delta":{"content":"Fix the "}}]}

        data: {"choices":[{"index":0,"delta":{"content":"café ✓"}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"total_tokens":5}}

        data: [DONE]


        """

    static let anthropicStream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type": "ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Fix the "}}

        : keepalive

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"café ✓"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}


        """

    struct StreamCase: Sendable, CustomTestStringConvertible {
        var wire: AIWire
        var payload: String
        var crlf: Bool
        var testDescription: String { "\(wire.rawValue)\(crlf ? " CRLF" : " LF")" }

        var bytes: [UInt8] {
            Array((crlf ? payload.replacingOccurrences(of: "\n", with: "\r\n") : payload).utf8)
        }
    }

    static let cases = [
        StreamCase(wire: .chatCompletions, payload: chatStream, crlf: false),
        StreamCase(wire: .chatCompletions, payload: chatStream, crlf: true),
        StreamCase(wire: .anthropicMessages, payload: anthropicStream, crlf: false),
        StreamCase(wire: .anthropicMessages, payload: anthropicStream, crlf: true),
    ]

    /// Feeds `bytes` cut at `cuts` (sorted offsets), then ends the body; returns the joined text and the deltas.
    static func parse(_ bytes: [UInt8], wire: AIWire, cuts: [Int]) throws -> (text: String, deltas: [AIStreamDelta]) {
        var parser = AISSEParser(wire: wire)
        var deltas: [AIStreamDelta] = []
        var start = 0
        for cut in cuts + [bytes.count] {
            deltas += try parser.consume(bytes[start..<cut])
            start = cut
        }
        deltas += try parser.finish()
        let text = deltas.reduce(into: "") { text, delta in
            if case .text(let piece) = delta { text += piece }
        }
        return (text, deltas)
    }

    @Test("the text is assembled the same when the stream is cut at any byte, for both wires", arguments: cases)
    func splitAtEveryOffset(_ stream: StreamCase) throws {
        let bytes = stream.bytes
        let whole = try Self.parse(bytes, wire: stream.wire, cuts: [])
        #expect(whole.text == "Fix the café ✓")
        #expect(whole.deltas.last == .done)
        #expect(whole.deltas.filter { $0 == .done }.count == 1)

        for cut in 1..<bytes.count {
            let split = try Self.parse(bytes, wire: stream.wire, cuts: [cut])
            #expect(split.deltas == whole.deltas, "cut at byte \(cut)")
        }
        let byteByByte = try Self.parse(bytes, wire: stream.wire, cuts: Array(1..<bytes.count))
        #expect(byteByByte.deltas == whole.deltas)
    }

    @Test("data: [DONE] ends the stream right where it comes, and an unterminated last event is still dispatched")
    func doneAndUnterminatedEvent() throws {
        let done = try Self.parse(Array("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n".utf8),
                                  wire: .chatCompletions, cuts: [])
        #expect(done.deltas == [.text("a"), .done])

        let cutOff = try Self.parse(Array("data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}".utf8),
                                    wire: .chatCompletions, cuts: [])
        #expect(cutOff.deltas == [.text("b")])
    }

    @Test("an error event in the stream becomes a provider error, on both wires", arguments: [
        (AIWire.chatCompletions, #"data: {"error":{"message":"overloaded"}}"#),
        (AIWire.anthropicMessages, "event: error\n" + #"data: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#),
    ])
    func errorEvent(wire: AIWire, payload: String) {
        #expect(throws: AIStreamError.provider("overloaded")) {
            _ = try Self.parse(Array((payload + "\n\n").utf8), wire: wire, cuts: [])
        }
    }
}
