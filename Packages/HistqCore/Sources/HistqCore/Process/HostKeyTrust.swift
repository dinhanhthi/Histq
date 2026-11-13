// Backs the "Trust host" banner: ssh runs with `BatchMode=yes`, so an unknown host key fails with
// `GitError.hostKey` instead of prompting. HostKeyTrust finds the host (from the error or the remote URL),
// scans its keys with `ssh-keyscan`, fingerprints them with `ssh-keygen -lf -` for the user to compare,
// and only when the user confirms appends exactly those lines to known_hosts. It never edits or removes a
// line. `ssh-keyscan` and `ssh-keygen` are found on the PATH of the environment it is given.
import Foundation

public struct HostKeyTrust: Sendable {
    public struct Host: Sendable, Hashable {
        public let name: String
        /// nil = the default port 22.
        public let port: Int?

        public init(name: String, port: Int? = nil) {
            self.name = name
            self.port = port
        }

        /// How known_hosts names it: `name`, or `[name]:port` for another port.
        public var knownHostsName: String {
            if let port, port != 22 { return "[\(name)]:\(port)" }
            return name
        }
    }

    public struct Key: Sendable, Hashable {
        /// The known_hosts line (`<host> <type> <base64>`), appended as is by `trust`.
        public let line: String
        public let type: String
        /// `SHA256:...` from `ssh-keygen -lf -`.
        public let fingerprint: String
    }

    public struct Scan: Sendable, Hashable {
        public let host: Host
        public let keys: [Key]
    }

    public enum TrustError: Error, Equatable, Sendable {
        /// Empty, starting with `-`, or containing whitespace, a control character or `,`.
        case invalidHost(String)
        case invalidPort(Int)
        case noKeys(host: String)
        case toolNotFound(String)
        case fingerprintFailed(String)
    }

    /// The key types asked for, in `ssh-keyscan -t` order.
    static let scanTypes = "ed25519,ecdsa,rsa"
    static let allowedKeyTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    /// The complete environment of `ssh-keyscan` and `ssh-keygen` (its PATH finds them).
    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// `~/.ssh/known_hosts`.
    public static var defaultKnownHosts: URL {
        URL(filePath: NSHomeDirectory()).appending(path: ".ssh/known_hosts")
    }

    // MARK: - Finding the host

    /// The host of a `.hostKey` error (`No <type> host key is known for <host> ...`, `Host key for <host>
    /// has changed ...`); nil for other errors or when ssh did not name it (use the remote URL then).
    public static func host(from error: GitError) -> Host? {
        guard case .hostKey(_, let tail) = error else { return nil }
        let patterns = [#"host key is known for (\S+) and"#, #"Host key for (\S+) has changed"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                let range = Range(match.range(at: 1), in: tail)
            else { continue }
            return parseHostToken(String(tail[range]))
        }
        return nil
    }

    /// True when ssh reported a changed key (a possible attack): the UI must warn instead of offering a
    /// plain "Trust host".
    public static func isKeyChanged(_ error: GitError) -> Bool {
        guard case .hostKey(_, let tail) = error else { return false }
        return tail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || tail.contains("has changed and you have")
    }

    /// The ssh host of a remote URL: `ssh://[user@]host[:port]/path` (also `git+ssh://`, `ssh+git://`,
    /// `[v6]` hosts) or scp-like `[user@]host:path`. nil for other transports and local paths.
    public static func host(fromRemoteURL url: String) -> Host? {
        for scheme in ["ssh://", "git+ssh://", "ssh+git://"] where url.lowercased().hasPrefix(scheme) {
            var rest = url.dropFirst(scheme.count)
            if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            return parseAuthority(String(rest))
        }
        if url.contains("://") { return nil }
        // scp-like: a colon before any slash; `./a:b` and `/a:b` are paths.
        guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
        var authority = url[..<colon]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("["), authority.hasSuffix("]") { authority = authority.dropFirst().dropLast() }
        guard !authority.isEmpty else { return nil }
        return Host(name: String(authority))
    }

    /// Throws unless `host` is safe to pass to ssh-keyscan and to write into known_hosts.
    /// Only host-name and IP characters are allowed (`:` for an IPv6 literal), so a written line can never
    /// carry known_hosts pattern syntax (`*`, `?`, `!`, `[`, `]`, `|`, `@`, `,`, `#`) or whitespace.
    public static func validate(_ host: Host) throws {
        let name = host.name
        let bad = name.unicodeScalars.contains { scalar in
            !(scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ".-_:".unicodeScalars.contains(scalar)))
        }
        guard !name.isEmpty, !name.hasPrefix("-"), !bad else { throw TrustError.invalidHost(name) }
        if let port = host.port, !(1...65535).contains(port) { throw TrustError.invalidPort(port) }
    }

    // MARK: - Scan and trust

    /// Scans the host's keys and fingerprints them. Writes nothing.
    public func scan(_ host: Host) async throws -> Scan {
        try Self.validate(host)
        let keyscan = try tool("ssh-keyscan")
        var args = ["-T", "5"]
        if let port = host.port { args += ["-p", String(port)] }
        args += ["-t", Self.scanTypes, "--", host.name]
        let output = try await GitRunner(executable: keyscan).run(
            args, cwd: workingDirectory, env: environment, timeout: .seconds(20), allowedExitCodes: [0, 1])
        let lines = Self.keyLines(output.text, host: host)
        guard !lines.isEmpty else { throw TrustError.noKeys(host: host.knownHostsName) }

        let keygen = try tool("ssh-keygen")
        var keys: [Key] = []
        for (line, type) in lines {
            let result = try await GitRunner(executable: keygen).run(
                ["-E", "sha256", "-lf", "-"], cwd: workingDirectory, env: environment, stdin: Data((line + "\n").utf8),
                timeout: .seconds(10), allowedExitCodes: [0, 1, 255])
            let fields = result.text.split(separator: " ")
            guard result.exitCode == 0, fields.count >= 2, fields[1].hasPrefix("SHA256:") else {
                throw TrustError.fingerprintFailed(result.stderrTail)
            }
            keys.append(Key(line: line, type: type, fingerprint: String(fields[1])))
        }
        return Scan(host: host, keys: keys)
    }

    /// Appends the scan's lines to `knownHosts` (created with mode 600, its folder with 700, if missing).
    /// Existing bytes are never changed; a missing final newline is added before the new lines.
    public func trust(_ scan: Scan, knownHosts: URL = HostKeyTrust.defaultKnownHosts) throws {
        try Self.validate(scan.host)
        guard !scan.keys.isEmpty else { throw TrustError.noKeys(host: scan.host.knownHostsName) }
        let folder = knownHosts.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(knownHosts.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: knownHosts.path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var text = scan.keys.map(\.line).joined(separator: "\n") + "\n"
        let size = try handle.seekToEnd()
        if size > 0 {
            let reader = try FileHandle(forReadingFrom: knownHosts)
            defer { try? reader.close() }
            try reader.seek(toOffset: size - 1)
            if reader.readData(ofLength: 1) != Data([0x0A]) { text = "\n" + text }
        }
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Helpers

    /// The `(line, type)` pairs of ssh-keyscan output naming exactly `host` with an allowed key type and a
    /// base64 key; comments and anything else are dropped.
    static func keyLines(_ output: String, host: Host) -> [(String, String)] {
        var result: [(String, String)] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let fields = raw.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0].lowercased() == host.knownHostsName.lowercased(), allowedKeyTypes.contains(String(fields[1])),
                Data(base64Encoded: String(fields[2])) != nil
            else { continue }
            result.append((fields.joined(separator: " "), String(fields[1])))
        }
        return result
    }

    private var workingDirectory: URL {
        URL(filePath: environment["TMPDIR"] ?? NSTemporaryDirectory(), directoryHint: .isDirectory)
    }

    /// The first executable `name` on the environment's PATH.
    private func tool(_ name: String) throws -> URL {
        for folder in (environment["PATH"] ?? "").split(separator: ":") where folder.hasPrefix("/") {
            let url = URL(filePath: String(folder), directoryHint: .isDirectory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw TrustError.toolNotFound(name)
    }

    /// `host`, `[host]:port`, or `host:port` (one colon only: a bare IPv6 address has several).
    private static func parseHostToken(_ token: String) -> Host? {
        if token.hasPrefix("["), let close = token.firstIndex(of: "]") {
            let name = String(token[token.index(after: token.startIndex)..<close])
            let rest = token[token.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return name.isEmpty ? nil : Host(name: name, port: port)
        }
        return token.isEmpty ? nil : Host(name: token)
    }

    private static func parseAuthority(_ authority: String) -> Host? {
        if authority.hasPrefix("[") { return parseHostToken(authority) }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) { return parts[0].isEmpty ? nil : Host(name: String(parts[0]), port: port) }
        return authority.isEmpty ? nil : Host(name: authority)
    }
}
