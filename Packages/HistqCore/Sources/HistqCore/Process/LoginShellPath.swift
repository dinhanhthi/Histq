// The login shell's PATH, for writes and network commands (clone, fetch, push, commit with hooks), so git-lfs,
// gpg, credential helpers and hooks find the user's tools. A GUI app only gets launchd's minimal PATH, and the
// login shell (`$SHELL -ilc`) takes seconds, so the last PATH is kept in a cache file whose location the app
// injects: a launch uses it at once and refreshes it in the background. Without a cache, `value()` waits for
// the shell. Automatic reads never use this PATH: they use `GitExecutable.fixedPath`.
//
// The cache is data only: one PATH string, never executed nor evaluated by a shell. A file that is not a
// valid PATH (see `isValid(_:)`) is ignored.
import Foundation

public actor LoginShellPath {
    /// The largest cache file read; a bigger one is ignored.
    static let maxCacheSize = 64 * 1024

    private let cacheFile: URL?
    private let resolver: @Sendable () async -> String?
    /// The newest valid PATH: the cache's, then the shell's.
    private var latest: String?
    private var cacheLoaded = false
    private var refresh: Task<String, Never>?

    /// `cacheFile`: where the last PATH is kept (nil: no cache). `resolver`: the raw PATH of the login shell, or
    /// nil when it could not be read (tests inject one; the default runs `$SHELL -ilc`).
    public init(
        cacheFile: URL?, resolver: @escaping @Sendable () async -> String? = { await LoginShellPath.shellPath() }
    ) {
        self.cacheFile = cacheFile
        self.resolver = resolver
    }

    /// Loads the cache and starts the one shell refresh of this instance without waiting: call at launch.
    public nonisolated func prepare() {
        Task.detached(priority: .utility) { _ = await self.value() }
    }

    /// The cached PATH at once when there is a valid one (the shell refresh then runs in the background), else
    /// the shell's, once it answered. If the shell fails, the inherited PATH plus Homebrew's folders.
    public func value() async -> String {
        loadCacheIfNeeded()
        let refresh = startRefresh()
        if let latest { return latest }
        return await refresh.value
    }

    /// A cache value is a PATH: not empty, no empty entry, every entry an absolute path, no newline, carriage
    /// return or NUL. The folders need not exist (a PATH may name missing ones). Checked on bytes, as the OS
    /// splits PATH: `\r\n` or `:` plus a combining mark is one Swift Character but two bytes.
    public static func isValid(_ path: String) -> Bool {
        let bytes = path.utf8
        guard !bytes.isEmpty, !bytes.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0 }) else { return false }
        return bytes.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
            .allSatisfy { $0.first == UInt8(ascii: "/") }
    }

    // MARK: - Cache

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard latest == nil, let cacheFile else { return }
        latest = Self.readCache(cacheFile)
    }

    /// The file's PATH, or nil when it is missing, not a regular file, too big, not UTF-8 or not a valid PATH.
    static func readCache(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= maxCacheSize,
              let data = try? Data(contentsOf: file),
              let text = String(validating: data, as: UTF8.self), isValid(text)
        else { return nil }
        return text
    }

    private static func writeCache(_ path: String, to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(path.utf8).write(to: file, options: .atomic)
    }

    // MARK: - Refresh

    private func startRefresh() -> Task<String, Never> {
        if let refresh { return refresh }
        let resolver = resolver
        let task = Task.detached(priority: .utility) {
            let raw = await resolver()
            return await self.finishRefresh(raw)
        }
        refresh = task
        return task
    }

    /// Keeps and caches the shell's PATH. A failed shell keeps the cached PATH, else falls back to the inherited
    /// PATH, which is not cached.
    private func finishRefresh(_ raw: String?) -> String {
        if let path = raw.map(Self.mergedPath), Self.isValid(path) {
            latest = path
            if let cacheFile { Self.writeCache(path, to: cacheFile) }
            return path
        }
        if let latest { return latest }
        return Self.mergedPath(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// `base` plus Homebrew's folders, without duplicates, empty or relative entries (a relative entry such as `.`
    /// would run a program from the repo git works in). Split on bytes, as `isValid(_:)`.
    static func mergedPath(_ base: String) -> String {
        var seen = Set<String>()
        let directories = base.utf8.split(separator: UInt8(ascii: ":")).map { String(decoding: $0, as: UTF8.self) }
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.filter { $0.utf8.first == UInt8(ascii: "/") && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    // MARK: - Login shell (ported from EchoKit's ShellEnvironment)

    /// The PATH printed by `$SHELL -ilc`, or nil when the shell failed or timed out (8 s).
    public static func shellPath() async -> String? {
        let output = await captureShell(
            URL(filePath: loginShell()), arguments: ["-ilc", "echo __BEGIN__; command env; echo __END__"],
            timeout: .seconds(8), until: Data("\n__END__\n".utf8))
        return parsePath(String(decoding: output, as: UTF8.self))
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
