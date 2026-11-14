// Wire protocols and base-URL validation for the AI providers (ported from Dblore's `AIEndpoint`). A base URL is
// where the API key is sent, so it must be https; plain http is only accepted for this Mac itself (a local
// OpenAI-compatible server), where nothing crosses the network. Credentials never go in the URL.
import Foundation

/// The wire protocol a provider speaks.
public enum AIWire: String, Codable, Sendable {
    /// OpenAI's `POST /chat/completions` (also Gemini's OpenAI-compatible endpoint, xAI and custom servers).
    case chatCompletions
    /// Anthropic's `POST /messages`.
    case anthropicMessages
}

public enum AIEndpointError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case invalidURL
    case unsupportedScheme
    case credentialsNotAllowed
    case missingHost
    case insecureRemoteHTTP

    public var description: String {
        switch self {
        case .empty: "Enter a base URL."
        case .invalidURL: "The base URL is not valid."
        case .unsupportedScheme: "The base URL must start with https:// (or http:// for this Mac)."
        case .credentialsNotAllowed:
            "Do not put a username or password in the base URL. Use the API key field instead."
        case .missingHost: "The base URL has no host name."
        case .insecureRemoteHTTP:
            "Plain http:// is only allowed for this Mac (localhost, 127.0.0.1, ::1). Use https://."
        }
    }
}

public enum AIEndpoint {
    /// Endpoint suffixes users commonly paste that are not part of the base URL.
    private static let strippedSuffixes = ["chat/completions", "messages", "responses", "models"]

    /// Validates and normalizes a user-entered base URL: trims it, refuses userinfo and non-https (http only for
    /// loopback), strips a pasted endpoint suffix, drops any query or fragment, and adds `/v1` to a bare host. Only
    /// a bare host gets `/v1`: a path the user gave is kept as is, so a base such as Gemini's `/v1beta/openai` or
    /// OpenRouter's `/api/v1` is not turned into a wrong one.
    public static func normalize(_ raw: String) throws(AIEndpointError) -> URL {
        let trimmed = trimSlashes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { throw .empty }
        guard var components = URLComponents(string: trimmed) else { throw .invalidURL }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw .unsupportedScheme
        }
        if components.user != nil || components.password != nil { throw .credentialsNotAllowed }
        guard let host = components.host, !host.isEmpty else { throw .missingHost }
        if scheme == "http" && !isLoopback(host) { throw .insecureRemoteHTTP }

        var path = trimSlashes(components.path)
        for suffix in strippedSuffixes where path == suffix || path.hasSuffix("/" + suffix) {
            path = trimSlashes(String(path.dropLast(suffix.count)))
            break
        }
        if path.isEmpty { path = "/v1" }

        components.scheme = scheme
        components.path = path.hasPrefix("/") ? path : "/" + path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw .invalidURL }
        return url
    }

    /// The streaming chat endpoint of `base` for `wire`.
    public static func chatURL(base: URL, wire: AIWire) -> URL {
        switch wire {
        case .chatCompletions: base.appendingPathComponent("chat/completions")
        case .anthropicMessages: base.appendingPathComponent("messages")
        }
    }

    private static func trimSlashes(_ value: String) -> String {
        var result = Substring(value)
        while result.hasSuffix("/") { result = result.dropLast() }
        return String(result)
    }

    /// `localhost`, an IPv4 literal in 127.0.0.0/8, or `::1` (with or without brackets). Narrower than Dblore,
    /// which also took private-network addresses: those are other machines, so plain http to them would send the
    /// key over the network in clear text.
    static func isLoopback(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            // Strict decimal octets: no empty part, no leading zero (some resolvers read those as octal).
            guard (1...3).contains(part.count), !(part.count > 1 && part.first == "0"),
                part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part), value <= 255
            else { return false }
        }
        return parts[0] == "127"
    }
}
