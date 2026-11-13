// Finds the git binary Histq runs: the path set in Settings, else the first `git` on the login shell's
// PATH, else `/usr/bin/git`. `/usr/bin/git` is only a shim: without the Command Line Tools it pops the
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
    /// No `git` on the PATH and no `/usr/bin/git`.
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

    /// `override` (a path from Settings, `~` allowed) when set, else the first `git` on the login shell's
    /// PATH, else `/usr/bin/git`. An override that is not executable throws instead of falling back, so
    /// Settings can show the problem. A `/usr/bin/git` found while the Command Line Tools are missing is
    /// skipped; if nothing else is found the result is `.commandLineToolsMissing`.
    public static func resolve(override: String? = nil) async throws -> GitExecutable {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            guard isExecutable(path) else { throw GitExecutableError.notExecutable(path: path) }
            return try await validate(at: URL(filePath: path))
        }
        var seen = Set<String>()
        var toolsMissing = false
        let directories = await loginShellPath().split(separator: ":").map(String.init) + ["/usr/bin"]
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

    /// The login shell's PATH plus Homebrew's directories, resolved once per launch (a GUI app only gets
    /// launchd's minimal PATH). Child processes get this PATH too.
    public static func loginShellPath() async -> String {
        await loginPath.value
    }

    private static let loginPath = Task.detached(priority: .utility) { await resolveLoginShellPath() }

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

    // MARK: - Login shell PATH (ported from EchoKit's ShellEnvironment)

    private static func resolveLoginShellPath() async -> String {
        let output = await captureShell(
            URL(filePath: loginShell()), arguments: ["-ilc", "echo __BEGIN__; command env; echo __END__"],
            timeout: .seconds(8), until: Data("\n__END__\n".utf8))
        let base = parsePath(String(decoding: output, as: UTF8.self))
            ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return mergedPath(base, extra: ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    /// The `PATH=` line between the markers of the login shell's output (rc files may print around them).
    static func parsePath(_ output: String) -> String? {
        guard let begin = output.range(of: "__BEGIN__\n") else { return nil }
        for line in output[begin.upperBound...].split(separator: "\n") {
            if line == "__END__" { break }
            if line.hasPrefix("PATH=") {
                let path = line.dropFirst(5).replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
                return path.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func mergedPath(_ base: String, extra: [String]) -> String {
        var seen = Set<String>()
        let directories = base.split(separator: ":").map(String.init) + extra
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Stdout of the shell (empty stdin) up to `marker` or EOF, for at most `timeout`; the shell is
    /// terminated if still running. It does not wait for the exit: a daemon started by an rc file can keep
    /// the pipe open, and an interactive shell may ignore SIGTERM.
    private static func captureShell(
        _ executable: URL, arguments: [String], timeout: Duration, until marker: Data
    ) async -> Data {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let output = ShellOutput()
        let (finished, finish) = AsyncStream<Void>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty || output.append(chunk, until: marker) { finish.finish() }
        }
        defer { stdout.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return Data() }
        let timer = Task {
            try await Task.sleep(for: timeout)
            finish.finish()
        }
        for await _ in finished {}
        timer.cancel()
        if process.isRunning { process.terminate() }
        return output.data
    }
}

/// The login shell's stdout, filled from the pipe's handler thread.
private final class ShellOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var data: Data { lock.withLock { buffer } }

    /// Appends `chunk`; true once `marker` has been seen.
    func append(_ chunk: Data, until marker: Data) -> Bool {
        lock.withLock {
            buffer.append(chunk)
            return buffer.range(of: marker) != nil
        }
    }
}
