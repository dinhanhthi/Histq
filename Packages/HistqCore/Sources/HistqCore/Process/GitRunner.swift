// Runs git as a child process: an argv array (never a shell), stdout and stderr drained concurrently,
// a bounded stderr tail, cancellation with SIGINT then SIGTERM, optional timeouts and a serialized
// lane for writes. The child-process plumbing is ported from SegDownCore's `ProcessIO`/`runProcess`.
import Foundation

/// The outcome of a git command that exited with an allowed code.
public struct GitResult: Sendable {
    public let exitCode: Int32
    /// Everything the command wrote to stdout.
    public let stdout: Data
    /// The last 8 KB of stderr.
    public let stderrTail: String

    /// `stdout` decoded as UTF-8 (invalid bytes replaced).
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Why a git command failed. Every case but `.timeout` and `.launchFailed` carries the exit code
/// (128 + the signal number when a signal killed git) and the last 8 KB of stderr.
public enum GitError: Error, Equatable, Sendable {
    case auth(exit: Int32, stderrTail: String)
    case hostKey(exit: Int32, stderrTail: String)
    case nonFastForward(exit: Int32, stderrTail: String)
    case conflict(exit: Int32, stderrTail: String)
    case indexLock(exit: Int32, stderrTail: String)
    /// The command ran longer than the timeout it was given.
    case timeout
    case other(exit: Int32, stderrTail: String)
    /// The executable could not be started.
    case launchFailed(String)

    public var exitCode: Int32? {
        switch self {
        case .auth(let exit, _), .hostKey(let exit, _), .nonFastForward(let exit, _), .conflict(let exit, _),
             .indexLock(let exit, _), .other(let exit, _):
            exit
        case .timeout, .launchFailed: nil
        }
    }

    public var stderrTail: String {
        switch self {
        case .auth(_, let tail), .hostKey(_, let tail), .nonFastForward(_, let tail), .conflict(_, let tail),
             .indexLock(_, let tail), .other(_, let tail):
            tail
        case .timeout: ""
        case .launchFailed(let message): message
        }
    }

    /// Classifies a failed command from its stderr tail and the end of its stdout
    /// (merge, rebase and stash report `CONFLICT (...)` on stdout).
    static func classify(exit: Int32, stderrTail: String, stdoutTail: String) -> GitError {
        let err = stderrTail.lowercased()
        let all = err + "\n" + stdoutTail.lowercased()
        let has = { (needles: [String], text: String) in needles.contains { text.contains($0) } }
        if has(["host key verification failed", "remote host identification has changed", "no matching host key"], err) {
            return .hostKey(exit: exit, stderrTail: stderrTail)
        }
        if err.contains("index.lock"), err.contains("file exists") {
            return .indexLock(exit: exit, stderrTail: stderrTail)
        }
        if has(["non-fast-forward", "[rejected]", "updates were rejected", "not possible to fast-forward",
                "diverging branches can't be fast-forwarded"], err) {
            return .nonFastForward(exit: exit, stderrTail: stderrTail)
        }
        if has(["conflict (", "automatic merge failed", "could not apply", "unmerged files", "unmerged paths",
                "needs merge"], all) {
            return .conflict(exit: exit, stderrTail: stderrTail)
        }
        if has(["permission denied (publickey", "authentication failed", "could not read username",
                "could not read password", "terminal prompts disabled", "invalid username or password"], err) {
            return .auth(exit: exit, stderrTail: stderrTail)
        }
        return .other(exit: exit, stderrTail: stderrTail)
    }
}

/// Runs git commands for one repository. `env` is always the complete child environment (nothing is
/// inherited from the app), so callers build it with `GitInvocation`.
public actor GitRunner {
    /// One line of output. Stdout is split on the stream's delimiter (empty lines kept); stderr is split
    /// on `\n` and `\r` (progress output), empty lines dropped.
    public struct Line: Sendable, Equatable {
        public enum Source: Sendable { case stdout, stderr }
        public let source: Source
        public let text: String
    }

    public let executable: URL
    /// The tail of the `mutate` lane: the last queued write, finished or not.
    private var lane: Task<Void, Never>?

    public init(executable: URL) {
        self.executable = executable
    }

    /// Runs `git <args>` in `cwd` to completion. Throws `GitError` unless it exits with one of
    /// `allowedExitCodes`, `GitError.timeout` once `timeout` passes (git is then stopped), and
    /// `CancellationError` when the calling task is cancelled (git gets SIGINT, then SIGTERM after 3 s).
    public func run(
        _ args: [String], cwd: URL, env: [String: String], stdin: Data? = nil, timeout: Duration? = nil,
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> GitResult {
        try Task.checkCancellation()
        let child = ChildProcess(
            executable: executable, arguments: args, cwd: cwd, environment: env, stdin: stdin, timeout: timeout,
            delimiter: nil, onLine: nil)
        try Self.launch(child)
        let outcome = await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.stop()
        }
        if Task.isCancelled { throw CancellationError() }
        if let error = outcome.error(allowing: allowedExitCodes) { throw error }
        return GitResult(exitCode: outcome.status, stdout: outcome.stdout, stderrTail: outcome.stderrText)
    }

    /// Runs `git <args>` in `cwd` and yields its output line by line as it arrives. The stream finishes
    /// when git exits 0 and throws `GitError` otherwise. Ending the iteration early (or cancelling the
    /// consuming task) stops git: SIGINT, then SIGTERM after 3 s. A cancelled consumer's loop ends without
    /// an error, so call `try Task.checkCancellation()` after the loop to tell it from a finished command.
    public func stream(
        _ args: [String], cwd: URL, env: [String: String], stdin: Data? = nil, timeout: Duration? = nil,
        delimiter: UInt8 = UInt8(ascii: "\n")
    ) -> AsyncThrowingStream<Line, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Line.self)
        let child = ChildProcess(
            executable: executable, arguments: args, cwd: cwd, environment: env, stdin: stdin, timeout: timeout,
            delimiter: delimiter, onLine: { continuation.yield($0) })
        continuation.onTermination = { _ in child.stop() }
        do {
            try Self.launch(child)
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        Task {
            let outcome = await child.wait()
            if let error = outcome.error(allowing: [0]) {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        return stream
    }

    /// Runs `body` after every write queued before it has finished, so writes in one repository run one at
    /// a time, in call order. A failing or cancelled body does not block the lane. Never call `mutate`
    /// from inside a `mutate` body of the same runner: the inner call waits for the outer one (deadlock).
    public func mutate<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = lane
        let work = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await body()
        }
        lane = Task { _ = await work.result }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func launch(_ child: ChildProcess) throws {
        do {
            try child.start()
        } catch {
            throw GitError.launchFailed(error.localizedDescription)
        }
    }
}

/// One child process with both pipes drained concurrently (so neither can fill up and block it).
/// With `onLine`, output is delivered as lines; without it, stdout is collected whole.
/// `wait()` returns once the process has exited and both pipes reached EOF, or 2 s after the exit
/// when a grandchild (an ssh ControlMaster, a credential helper) still holds a pipe open.
final class ChildProcess: @unchecked Sendable {
    struct Outcome: Sendable {
        var status: Int32
        var reason: Process.TerminationReason
        /// Everything written to stdout when collecting, else empty.
        var stdout: Data
        var stdoutTail: Data
        var stderrTail: Data
        var timedOut: Bool

        var stderrText: String { String(decoding: stderrTail, as: UTF8.self) }

        /// The error for this outcome, nil when the process exited with an allowed code.
        func error(allowing allowed: Set<Int32>) -> GitError? {
            if timedOut { return .timeout }
            if reason == .exit, allowed.contains(status) { return nil }
            let exit = reason == .exit ? status : 128 + status
            return GitError.classify(
                exit: exit, stderrTail: stderrText, stdoutTail: String(decoding: stdoutTail, as: UTF8.self))
        }
    }

    static let tailBytes = 8 * 1024
    static let cancelGracePeriod: TimeInterval = 3
    static let eofGracePeriod: TimeInterval = 2
    /// A stderr line longer than this is not useful progress; its start is dropped to bound memory.
    static let maxStderrLineBytes = 64 * 1024

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe: Pipe?
    private let stdinData: Data?
    private let timeout: Duration?
    private let delimiter: UInt8?
    private let onLine: (@Sendable (GitRunner.Line) -> Void)?

    private let lock = NSLock()
    private var collected = Data()
    private var pendingStdout = Data()
    private var pendingStderr = Data()
    private var stdoutTail = Data()
    private var stderrTail = Data()
    private var openStreams = 2
    private var launched = false
    private var stopRequested = false
    private var timedOut = false
    private var exit: (status: Int32, reason: Process.TerminationReason)?
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var timer: Task<Void, Never>?

    /// `delimiter` and `onLine` go together: both nil collects stdout, both set streams lines.
    init(
        executable: URL, arguments: [String], cwd: URL?, environment: [String: String], stdin: Data?,
        timeout: Duration?, delimiter: UInt8?, onLine: (@Sendable (GitRunner.Line) -> Void)?
    ) {
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = environment
        stdinData = stdin
        stdinPipe = stdin == nil ? nil : Pipe()
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        self.timeout = timeout
        self.delimiter = delimiter
        self.onLine = onLine
    }

    /// Launches the process. A `stop()` that arrived earlier takes effect right after the launch.
    func start() throws {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            read(handle.availableData, from: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            read(handle.availableData, from: .stderr)
        }
        process.terminationHandler = { [self] process in
            exited(status: process.terminationStatus, reason: process.terminationReason)
        }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw error
        }
        writeStdin()
        if let timeout {
            let timer = Task { [self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                timeoutFired()
            }
            lock.withLock { self.timer = timer }
        }
        let stopNow = lock.withLock {
            launched = true
            return stopRequested
        }
        if stopNow { signalStop() }
    }

    /// Stops the process: SIGINT now, SIGTERM after 3 s if it is still running. No-op once it exited.
    func stop() {
        let send = lock.withLock {
            guard exit == nil, !stopRequested else { return false }
            stopRequested = true
            return launched
        }
        if send { signalStop() }
    }

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func signalStop() {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGracePeriod) { [self] in
            if process.isRunning { process.terminate() }
        }
    }

    private func timeoutFired() {
        let fire = lock.withLock {
            guard exit == nil else { return false }
            timedOut = true
            return true
        }
        if fire { stop() }
    }

    /// Writes stdin on a background queue (git may read it only after writing output) and closes it.
    /// `F_SETNOSIGPIPE` turns a write to a child that already exited into an error instead of SIGPIPE.
    private func writeStdin() {
        guard let stdinPipe, let stdinData else { return }
        let handle = stdinPipe.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: stdinData)
            try? handle.close()
        }
    }

    private func read(_ data: Data, from source: GitRunner.Line.Source) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        if data.isEmpty {
            (source == .stdout ? stdoutPipe : stderrPipe).fileHandleForReading.readabilityHandler = nil
            flush(source)
            openStreams -= 1
            finishIfReady(force: false)
            return
        }
        switch source {
        case .stdout:
            Self.appendTail(data, to: &stdoutTail)
            if let delimiter {
                pendingStdout.append(data)
                emitLines(from: &pendingStdout, source: .stdout) { $0 == delimiter }
            } else {
                collected.append(data)
            }
        case .stderr:
            Self.appendTail(data, to: &stderrTail)
            guard onLine != nil else { return }
            pendingStderr.append(data)
            emitLines(from: &pendingStderr, source: .stderr) { $0 == 0x0A || $0 == 0x0D }
            if pendingStderr.count > Self.maxStderrLineBytes { pendingStderr = Data() }
        }
    }

    /// Emits every complete line in `buffer` (called with the lock held, so lines keep their order and
    /// none is emitted after the outcome) and keeps the unterminated rest.
    private func emitLines(from buffer: inout Data, source: GitRunner.Line.Source, isEnd: (UInt8) -> Bool) {
        var start = buffer.startIndex
        while let end = buffer[start...].firstIndex(where: isEnd) {
            emit(buffer[start..<end], source: source)
            start = buffer.index(after: end)
        }
        if start != buffer.startIndex { buffer = Data(buffer[start...]) }
    }

    private func emit(_ line: Data, source: GitRunner.Line.Source) {
        if source == .stderr, line.isEmpty { return }
        onLine?(GitRunner.Line(source: source, text: String(decoding: line, as: UTF8.self)))
    }

    /// Emits the unterminated last line of `source`, if any.
    private func flush(_ source: GitRunner.Line.Source) {
        guard onLine != nil else { return }
        let rest = source == .stdout ? pendingStdout : pendingStderr
        if !rest.isEmpty { emit(rest, source: source) }
        if source == .stdout { pendingStdout = Data() } else { pendingStderr = Data() }
    }

    private static func appendTail(_ data: Data, to tail: inout Data) {
        tail.append(data)
        if tail.count > tailBytes { tail = Data(tail.suffix(tailBytes)) }
    }

    private func exited(status: Int32, reason: Process.TerminationReason) {
        lock.withLock {
            exit = (status, reason)
            finishIfReady(force: false)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.eofGracePeriod) { [self] in
            lock.withLock { finishIfReady(force: true) }
        }
    }

    /// Publishes the outcome once the process exited and both pipes closed (or `force`). Lock held.
    private func finishIfReady(force: Bool) {
        guard outcome == nil, let exit, force || openStreams == 0 else { return }
        if force {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            flush(.stdout)
            flush(.stderr)
        }
        timer?.cancel()
        let result = Outcome(
            status: exit.status, reason: exit.reason, stdout: collected, stdoutTail: stdoutTail,
            stderrTail: stderrTail, timedOut: timedOut)
        outcome = result
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: result)
    }
}

extension ChildProcess {
    /// Runs a short command to completion with an empty stdin and returns its outcome (stdout collected),
    /// or nil when it cannot be started. It is stopped once `timeout` passes.
    static func capture(
        _ executable: URL, arguments: [String], environment: [String: String], timeout: Duration
    ) async -> Outcome? {
        let child = ChildProcess(
            executable: executable, arguments: arguments, cwd: nil, environment: environment, stdin: nil,
            timeout: timeout, delimiter: nil, onLine: nil)
        do {
            try child.start()
        } catch {
            return nil
        }
        return await child.wait()
    }
}
