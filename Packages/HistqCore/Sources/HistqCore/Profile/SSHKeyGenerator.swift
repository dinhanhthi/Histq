// Backs "Generate key" in the SSH settings: runs `ssh-keygen -t ed25519 -C <comment> -f <path> -N ''` and
// returns the new public key for the user to copy. The key has no passphrase on purpose: `-N <passphrase>` would
// put the passphrase in argv, where any local process can read it, so the UI tells the user to add one later
// with `ssh-keygen -p -f <path>` and `ssh-add --apple-use-keychain <path>`.
//
// It never replaces a key: an existing private or public key file (even a dangling symlink, which ssh-keygen
// would write through) stops it before anything runs. The comment and path are checked first too, so neither can
// pass for an option nor split the one-line public key. `ssh-keygen` is found on the PATH of the environment it
// is given, as in `HostKeyTrust`.
import Foundation

public struct SSHKeyGenerator: Sendable {
    public enum GenerateError: Error, Equatable, Sendable {
        /// Starting with `-`, or containing a control character (a newline would split the public key line).
        case invalidComment(String)
        /// Not absolute, a folder, a file name starting with `-`, or containing a control character.
        case invalidPath(String)
        /// The private key or its `.pub` already exists.
        case keyExists(path: String)
        case toolNotFound(String)
        /// ssh-keygen failed or wrote no readable public key.
        case failed(String)
    }

    /// The complete environment of `ssh-keygen` (its PATH finds it).
    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// Creates an unencrypted ed25519 key pair at `privateKey` and `privateKey.pub` and returns the public key
    /// line (`ssh-ed25519 <base64> <comment>`, no final newline). `privateKey` must be an absolute file path (the
    /// UI expands `~`); a missing folder is created with mode 700. ssh-keygen writes the private key with mode 600.
    public func generate(privateKey: URL, comment: String) async throws -> String {
        try Self.validate(comment: comment)
        let path = privateKey.path(percentEncoded: false)
        try Self.validate(path: path)
        let publicPath = path + ".pub"
        for existing in [path, publicPath] where Self.entryExists(existing) {
            throw GenerateError.keyExists(path: existing)
        }
        let keygen = try tool("ssh-keygen")
        let folder = privateKey.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Without stdin the child reads /dev/null, so if a private key appears between the check and this run,
        // ssh-keygen's "Overwrite (y/n)?" reads EOF and exits 1 without writing.
        let result = try await GitRunner(executable: keygen).run(
            ["-t", "ed25519", "-C", comment, "-f", path, "-N", ""], cwd: folder, env: environment,
            timeout: .seconds(30), allowedExitCodes: [0, 1, 255])
        guard result.exitCode == 0 else { throw GenerateError.failed(result.stderrTail) }
        guard let data = FileManager.default.contents(atPath: publicPath),
              let text = String(data: data, encoding: .utf8)
        else { throw GenerateError.failed("no public key at \(publicPath)") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Validation

    /// Throws unless `comment` is safe as the `-C` value and as the last field of the public key line. Empty is
    /// allowed (ssh-keygen then writes no comment).
    public static func validate(comment: String) throws {
        guard !comment.hasPrefix("-"), !hasControlCharacter(comment) else { throw GenerateError.invalidComment(comment) }
    }

    /// Throws unless `path` is an absolute file path with no control character whose file name does not start
    /// with `-`.
    public static func validate(path: String) throws {
        let name = (path as NSString).lastPathComponent
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !name.isEmpty, !name.hasPrefix("-"),
              !hasControlCharacter(path)
        else { throw GenerateError.invalidPath(path) }
    }

    /// Checked on scalars, not Characters: `\r\n` is one Character, and NUL and DEL must be caught too.
    private static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }
    }

    // MARK: - Helpers

    /// True when anything is at `path`, a dangling symlink included (`lstat`, unlike `fileExists`).
    private static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// The first executable `name` on the environment's PATH.
    private func tool(_ name: String) throws -> URL {
        for folder in (environment["PATH"] ?? "").split(separator: ":") where folder.hasPrefix("/") {
            let url = URL(filePath: String(folder), directoryHint: .isDirectory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw GenerateError.toolNotFound(name)
    }
}
