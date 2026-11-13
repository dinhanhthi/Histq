// Builds the complete environment of a git child process (GitRunner inherits nothing): the profile is
// injected as command-scope config (`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`, which beats
// `.git/config`) and `GIT_SSH_COMMAND`, and git never prompts.
//
// Reads (status, log, diff, show, for-each-ref, watcher refreshes) also get a safety block, because a
// downloaded repo's `.git/config`, `.git/info/attributes` and hooks could otherwise make an automatic read
// run a command: no fsmonitor hook, no signature check (`gpg.program`), no inline submodule diff (a child
// `git diff` without `--no-ext-diff`), no index refresh write, no hooks, no external diff (`diff.external`),
// every filter driver and every diff driver (`textconv`, `command`) configured where the read runs
// disabled (an empty command: git fails to run it, so a read that does not pass `--no-ext-diff
// --no-textconv` fails instead of running it), no transport at all (`GIT_ALLOW_PROTOCOL` empty, which beats
// the repo's `protocol.<name>.allow`, and `GIT_NO_LAZY_FETCH` on git >= 2.44), so a partial clone's
// promisor remote never fetches through its `uploadpack` or `core.sshCommand`, and UTF-8 log output (a
// repo's `i18n.logOutputEncoding` such as UTF-16 would put NUL bytes in the NUL-terminated log records).
// Writes (user actions) keep the normal behavior, so git-lfs and hooks work.
import Foundation

public enum GitInvocation {
    public enum Access: Sendable, Equatable {
        /// A user action: the repo's hooks, filters and helpers run as with the git CLI.
        case write
        /// An automatic read in a folder whose config names `filterDrivers` and `diffDrivers` (see
        /// `filterDrivers(runner:cwd:env:)` and `diffDrivers(runner:cwd:env:)`).
        case read(filterDrivers: [String], diffDrivers: [String] = [])
    }

    /// The base every invocation starts from: `path` as PATH, HOME, and the few inherited variables ssh and gpg
    /// need to reach their agents. Reads use the default, the fixed `GitExecutable.fixedPath`, so they never wait
    /// for the login shell; writes and network commands pass `LoginShellPath.value()` (a GUI app only gets
    /// launchd's PATH, which misses git-lfs, gpg and the tools hooks call).
    public static func baseEnvironment(
        path: String = GitExecutable.fixedPath, home: String = NSHomeDirectory(),
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = ["PATH": path, "HOME": home]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "GNUPGHOME"] {
            if let value = inherited[key] { env[key] = value }
        }
        return env
    }

    /// `base` plus the profile and, for reads, the safety block. Config entries are appended after any
    /// `GIT_CONFIG_*` entries already in `base`; within command scope the last one wins.
    public static func environment(profile: Profile?, base: [String: String], access: Access = .write)
        -> [String: String]
    {
        var env = base
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        var config: [(String, String)] = []
        if let profile {
            config += identityConfig(profile)
            config += signingConfig(profile)
        }
        env["GIT_SSH_COMMAND"] = sshCommand(profile?.ssh ?? .agent)
        if case .read(let filterDrivers, let diffDrivers) = access {
            env["GIT_OPTIONAL_LOCKS"] = "0"
            env["GIT_NO_LAZY_FETCH"] = "1"
            // An empty allow list: no transport (`file`, `ssh`, `ext`, remote helpers...) may run.
            env["GIT_ALLOW_PROTOCOL"] = ""
            config += readSafetyConfig
            for driver in filterDrivers {
                let section = "filter.\(driver)"
                config += [("\(section).clean", ""), ("\(section).smudge", ""), ("\(section).process", ""),
                           ("\(section).required", "false")]
            }
            for driver in diffDrivers {
                config += [("diff.\(driver).textconv", ""), ("diff.\(driver).command", "")]
            }
        }
        append(config, to: &env)
        return env
    }

    /// The read environment for a read run in `cwd`: lists the filter and diff drivers configured there first.
    public static func readEnvironment(profile: Profile?, base: [String: String], runner: GitRunner, cwd: URL)
        async throws -> [String: String]
    {
        let listingEnv = environment(profile: profile, base: base, access: .read(filterDrivers: []))
        let filters = try await filterDrivers(runner: runner, cwd: cwd, env: listingEnv)
        let diffs = try await diffDrivers(runner: runner, cwd: cwd, env: listingEnv)
        return environment(profile: profile, base: base, access: .read(filterDrivers: filters, diffDrivers: diffs))
    }

    /// The filter driver names (`filter.<name>.*`) of every config scope git reads in `cwd`, including
    /// includes and the worktree's `config.worktree`. `git config` itself runs nothing. The names come
    /// from the repo, so they are parsed as bytes (no Unicode normalization or grapheme merging) and a
    /// name that is not valid UTF-8 (which no environment string can carry) throws. Any git failure but
    /// "no match" (exit 1) throws too, so a read never runs without its overrides.
    public static func filterDrivers(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [String] {
        try await subsections(of: "filter", runner: runner, cwd: cwd, env: env, notUTF8: .filterDriverNotUTF8)
    }

    /// The diff driver names (`diff.<name>.*`), listed as `filterDrivers(runner:cwd:env:)` lists filters.
    /// Two-part keys such as `diff.external` name no driver and are skipped.
    public static func diffDrivers(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [String] {
        try await subsections(of: "diff", runner: runner, cwd: cwd, env: env, notUTF8: .diffDriverNotUTF8)
    }

    public enum ReadSafetyError: Error, Equatable, Sendable {
        /// The config names a filter driver whose name is not valid UTF-8, so it cannot be disabled.
        case filterDriverNotUTF8
        /// The config names a diff driver whose name is not valid UTF-8, so it cannot be disabled.
        case diffDriverNotUTF8
    }

    /// The subsection names of `section` (`<section>.<name>.<variable>` keys) in every config scope of `cwd`.
    private static func subsections(
        of section: String, runner: GitRunner, cwd: URL, env: [String: String], notUTF8: ReadSafetyError
    ) async throws -> [String] {
        let result = try await runner.run(
            ["config", "-z", "--name-only", "--get-regexp", "^\(section)\\."], cwd: cwd, env: env,
            timeout: .seconds(10), allowedExitCodes: [0, 1])
        let prefix = Array("\(section).".utf8)
        var names: [String] = []
        for key in result.stdout.split(separator: 0) {
            // `<section>.<name>.<variable>`: the name is everything between the first and the last dot.
            guard key.starts(with: prefix), let lastDot = key.lastIndex(of: UInt8(ascii: ".")) else { continue }
            let start = key.startIndex + prefix.count
            guard start < lastDot else { continue }
            guard let name = String(validating: key[start..<lastDot], as: UTF8.self) else { throw notUTF8 }
            names.append(name)
        }
        return names
    }

    /// `ssh -o BatchMode=yes`, plus `-i '<path>' -o IdentitiesOnly=yes` for a key file. Git runs it with
    /// `/bin/sh -c`, so the path is single-quoted.
    static func sshCommand(_ key: Profile.SSHKey) -> String {
        switch key {
        case .agent: "ssh -o BatchMode=yes"
        case .keyFile(let path): "ssh -o BatchMode=yes -i \(shellQuoted(path)) -o IdentitiesOnly=yes"
        }
    }

    /// POSIX single quoting: `'` becomes `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }

    /// `author.*` and `committer.*` too: a repo's own `author.name` would otherwise beat `user.name`.
    private static func identityConfig(_ profile: Profile) -> [(String, String)] {
        let name = profile.identity.name
        let email = profile.identity.email
        return [("user.name", name), ("user.email", email), ("author.name", name), ("author.email", email),
                ("committer.name", name), ("committer.email", email)]
    }

    private static func signingConfig(_ profile: Profile) -> [(String, String)] {
        switch profile.signing {
        case .none:
            [("commit.gpgSign", "false")]
        case .gpg(let keyID):
            [("gpg.format", "openpgp"), ("user.signingKey", keyID),
             ("commit.gpgSign", profile.signByDefault ? "true" : "false")]
        case .ssh(let keyPath):
            [("gpg.format", "ssh"), ("user.signingKey", keyPath),
             ("commit.gpgSign", profile.signByDefault ? "true" : "false")]
        }
    }

    private static let readSafetyConfig: [(String, String)] = [
        ("core.fsmonitor", "false"),
        ("log.showSignature", "false"),
        ("diff.submodule", "short"),
        ("diff.autoRefreshIndex", "false"),
        ("core.hooksPath", "/dev/null"),
        ("diff.external", ""),
        ("i18n.logOutputEncoding", "UTF-8"),
    ]

    private static func append(_ config: [(String, String)], to env: inout [String: String]) {
        var index = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        for (key, value) in config {
            env["GIT_CONFIG_KEY_\(index)"] = key
            env["GIT_CONFIG_VALUE_\(index)"] = value
            index += 1
        }
        if index > 0 { env["GIT_CONFIG_COUNT"] = String(index) }
    }
}
