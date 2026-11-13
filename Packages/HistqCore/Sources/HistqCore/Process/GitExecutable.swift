// Finds the git binary Histq runs: the path set in Settings, else the first `git` in a fixed list of folders
// (Homebrew on Apple silicon, then Intel, then `/usr/bin`), so no read waits for the login shell (see
// `LoginShellPath`). `/usr/bin/git` is only a shim: without the Command Line Tools it pops the
// installer, so it is never run before `xcode-select -p` succeeds. Git older than 2.36 is rejected:
// `GIT_CONFIG_COUNT` needs 2.31, `worktree list --porcelain -z` and a boolean `core.fsmonitor` need 2.36.
import Foundation

/// A git version such as `2.39.5`.
public struct GitVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `git --version` output: `git version 2.39.5 (Apple Git-154)`, `git version 2.47.0.rc1`,
    /// `git version 2.45.0.windows.1`.
    public init?(parsing output: String) {
        guard let marker = output.range(of: "git version ") else { return nil }
        let token = output[marker.upperBound...].prefix { !$0.isWhitespace }
        let numbers = token.split(separator: ".", omittingEmptySubsequences: false).prefix(3)
            .map { Int($0.prefix { $0.isASCII && $0.isNumber }) }
        guard numbers.count >= 2, let major = numbers[0], let minor = numbers[1] else { return nil }
        self.init(major, minor, numbers.count == 3 ? numbers[2] ?? 0 : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Why no usable git was found.
public enum GitExecutableError: Error, Equatable, Sendable {
    /// Only `/usr/bin/git` is available and the Command Line Tools are not installed.
    case commandLineToolsMissing
    /// No `git` in any of `GitExecutable.searchDirectories`.
    case notFound
    /// The path set in Settings is not an executable file (or could not be started).
    case notExecutable(path: String)
    /// The git found is older than `GitExecutable.minimumVersion`.
    case tooOld(GitVersion)
    /// `git --version` failed or printed something unexpected (its output, trimmed).
    case unrecognizedVersion(String)
}

/// A git binary that was checked to run and to be recent enough.
public struct GitExecutable: Sendable, Equatable {
    public static let minimumVersion = GitVersion(2, 36)
    static let appleGitPath = "/usr/bin/git"

    public let url: URL
    public let version: GitVersion

    /// Where `resolve` looks for git, in order, when no override is set.
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// The fixed PATH of automatic reads: known at once, unlike the login shell's (`LoginShellPath`).
    public static let fixedPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// `override` (a path from Settings, `~` allowed) when set, else the first executable `git` in
    /// `directories` (`searchDirectories` by default). An override that is not executable throws instead of
    /// falling back, so Settings can show the problem. A `/usr/bin/git` found while the Command Line Tools are
    /// missing is skipped; if nothing else is found the result is `.commandLineToolsMissing`. It never waits
    /// for the login shell: it takes a `git --version` (and `xcode-select -p` for `/usr/bin/git`).
    public static func resolve(
        override: String? = nil, directories: [String] = searchDirectories
    ) async throws -> GitExecutable {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            guard isExecutable(path) else { throw GitExecutableError.notExecutable(path: path) }
            return try await validate(at: URL(filePath: path))
        }
        var seen = Set<String>()
        var toolsMissing = false
        for directory in directories where directory.hasPrefix("/") && seen.insert(directory).inserted {
            let candidate = URL(filePath: directory).appending(path: "git")
            guard isExecutable(candidate.path) else { continue }
            do {
                return try await validate(at: candidate)
            } catch GitExecutableError.commandLineToolsMissing {
                toolsMissing = true
            }
        }
        throw toolsMissing ? GitExecutableError.commandLineToolsMissing : GitExecutableError.notFound
    }

    /// Checks the git at `url`: the Command Line Tools first when it is `/usr/bin/git` (symlinks resolved),
    /// then `git --version` against `minimumVersion`.
    public static func validate(at url: URL) async throws -> GitExecutable {
        if url.resolvingSymlinksInPath().path == appleGitPath, !(await commandLineToolsInstalled()) {
            throw GitExecutableError.commandLineToolsMissing
        }
        guard let outcome = await ChildProcess.capture(
            url, arguments: ["--version"], environment: minimalEnvironment, timeout: .seconds(5))
        else { throw GitExecutableError.notExecutable(path: url.path) }
        let output = String(decoding: outcome.stdout, as: UTF8.self)
        guard outcome.reason == .exit, outcome.status == 0, !outcome.timedOut,
              let version = GitVersion(parsing: output)
        else { throw GitExecutableError.unrecognizedVersion(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard version >= minimumVersion else { throw GitExecutableError.tooOld(version) }
        return GitExecutable(url: url, version: version)
    }

    private static let minimalEnvironment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LC_ALL": "C",
    ]

    /// `xcode-select -p` exits 0 when the Command Line Tools (or Xcode) are installed. It never runs the
    /// installer, unlike the `/usr/bin/git` shim.
    static func commandLineToolsInstalled() async -> Bool {
        let outcome = await ChildProcess.capture(
            URL(filePath: "/usr/bin/xcode-select"), arguments: ["-p"], environment: minimalEnvironment,
            timeout: .seconds(5))
        guard let outcome else { return false }
        return outcome.reason == .exit && outcome.status == 0 && !outcome.timedOut
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
