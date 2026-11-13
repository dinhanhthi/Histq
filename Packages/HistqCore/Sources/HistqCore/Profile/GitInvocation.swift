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
//
// A fetch nobody clicked (auto-fetch) gets its own block, because it is network and runs on a timer in a
// repo that may be downloaded: only the ssh, https and git transports (no `file`, `ext` or remote helper,
// so a repo's `uploadpack`, `insteadOf` or `vcs` cannot run a local command), no git proxy command, no
// alternate refs command, no hooks, no fsmonitor, no submodule fetch, no prompt or askpass (an askpass that
// fails also beats a repo's `core.askPass`), no cookie file written, no gc or maintenance, an ssh that gives
// up on a dead host, and only the credential helpers of the user's own config (system, global, Xcode's):
// the list is reset and refilled after the repo's `credential.*helper` entries. A repo that sets its own
// `http.*` or `remote.<name>.proxy` config is not fetched in the background at all, since those keys could
// send the user's credentials to a third party.
import Foundation

public enum GitInvocation {
    public enum Access: Sendable, Equatable {
        /// A user action: the repo's hooks, filters and helpers run as with the git CLI.
        case write
        /// An automatic read in a folder whose config names `filterDrivers` and `diffDrivers` (see
        /// `filterDrivers(runner:cwd:env:)` and `diffDrivers(runner:cwd:env:)`).
        case read(filterDrivers: [String], diffDrivers: [String] = [])
        /// A fetch nobody clicked, with the user's own `credentialHelpers` (see
        /// `credentialHelpers(runner:cwd:env:)`).
        case backgroundFetch(credentialHelpers: [ConfigEntry])
    }

    /// One config entry as git lists it: `credential.https://github.com.helper` and its value.
    public struct ConfigEntry: Sendable, Equatable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
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

    /// `base` plus the profile and, for reads and background fetches, their safety block. Config entries are
    /// appended after any `GIT_CONFIG_*` entries already in `base`; within command scope the last one wins.
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
        if case .backgroundFetch(let credentialHelpers) = access {
            env["GIT_ALLOW_PROTOCOL"] = "ssh:https:git"
            // Set but empty: git then ignores every `core.gitProxy` and connects to a git:// host itself.
            env["GIT_PROXY_COMMAND"] = ""
            env["GIT_ASKPASS"] = "/usr/bin/false"
            env["SSH_ASKPASS"] = "/usr/bin/false"
            env["GIT_SSH_COMMAND"]? += " -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
            config += backgroundFetchConfig
            // An empty helper clears the list git built so far (every scope and URL, the repo's included);
            // the user's own helpers then come back in their order.
            config.append(("credential.helper", ""))
            config += credentialHelpers.map { ($0.key, $0.value) }
        }
        append(config, to: &env)
        return env
    }

    /// The background fetch environment for a fetch run in `cwd`: lists the user's credential helpers first, and
    /// throws `BackgroundFetchError.repoSetsNetworkConfig` for a repo with its own http or proxy config.
    public static func backgroundFetchEnvironment(
        profile: Profile?, base: [String: String], runner: GitRunner, cwd: URL
    ) async throws -> [String: String] {
        let listingEnv = environment(profile: nil, base: base, access: .read(filterDrivers: []))
        let helpers = try await credentialHelpers(runner: runner, cwd: cwd, env: listingEnv)
        return environment(profile: profile, base: base, access: .backgroundFetch(credentialHelpers: helpers))
    }

    /// The `credential.helper` and `credential.<url>.helper` entries (empty resets included, in git's order) of
    /// every scope git reads in `cwd` but the repo's own (`local`, `worktree`): system, global, command and
    /// `unknown`, which is where Apple's git keeps Xcode's `osxkeychain` (not listed by `--system`). Listed in
    /// `cwd`, so a global `includeIf "gitdir:..."` applies as it does for git; an included file has the scope
    /// of the file that includes it. A valueless entry (which makes git fail anyway) is skipped; a value that is
    /// not valid UTF-8 and any git failure but "no match" throw, so a fetch never runs with a partial list.
    ///
    /// The same listing throws `BackgroundFetchError.repoSetsNetworkConfig` when the repo's own scopes set any
    /// `http.*` key (`http.<url>.*` too) or a `remote.<name>.proxy`: a repo's proxy, `sslVerify=false`,
    /// `sslCAInfo` or `extraHeader` could make a fetch nobody clicked hand the user's stored credentials to a
    /// third party. A fetch the user clicks still runs with them.
    public static func credentialHelpers(runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> [ConfigEntry]
    {
        let pattern = "^(credential\\.(.*\\.)?helper|http\\..*|remote\\..*\\.proxy)$"
        let result = try await runner.run(
            ["config", "-z", "--show-scope", "--get-regexp", pattern], cwd: cwd, env: env,
            timeout: .seconds(10), allowedExitCodes: [0, 1])
        let userScopes: Set<String> = ["system", "global", "command", "unknown"]
        let credentialPrefix = Array("credential.".utf8)
        var entries: [ConfigEntry] = []
        var repoNetworkKeys: [String] = []
        // `<scope>\0<key>\n<value>\0` per entry; a valueless entry has no `\n<value>`.
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        while index + 1 < fields.count {
            let scope = String(decoding: fields[index], as: UTF8.self)
            let entry = fields[index + 1]
            index += 2
            let newline = entry.firstIndex(of: UInt8(ascii: "\n"))
            let keyBytes = entry[..<(newline ?? entry.endIndex)]
            let isCredential = keyBytes.starts(with: credentialPrefix)
            guard userScopes.contains(scope) else {
                // The repo's own helpers are dropped by the reset; its http and proxy keys stop the fetch.
                if !isCredential { repoNetworkKeys.append(String(decoding: keyBytes, as: UTF8.self)) }
                continue
            }
            guard isCredential, let newline else { continue }
            guard let key = String(validating: keyBytes, as: UTF8.self),
                  let value = String(validating: entry[(newline + 1)...], as: UTF8.self)
            else { throw ReadSafetyError.credentialHelperNotUTF8 }
            entries.append(ConfigEntry(key: key, value: value))
        }
        if !repoNetworkKeys.isEmpty { throw BackgroundFetchError.repoSetsNetworkConfig(keys: repoNetworkKeys) }
        return entries
    }

    public enum BackgroundFetchError: Error, Equatable, Sendable {
        /// The repo's own config sets these `http.*` or `remote.<name>.proxy` keys, so it is not fetched unless
        /// the user asks.
        case repoSetsNetworkConfig(keys: [String])
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
        /// The user's config has a credential helper entry that is not valid UTF-8, so it cannot be passed on.
        case credentialHelperNotUTF8
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

    /// A signing method without a key (`Signing.isUsable` false) signs nothing, as `.none`: never an empty
    /// `user.signingKey`.
    private static func signingConfig(_ profile: Profile) -> [(String, String)] {
        guard profile.signing.isUsable else { return [("commit.gpgSign", "false")] }
        switch profile.signing {
        case .none:
            return [("commit.gpgSign", "false")]
        case .gpg(let keyID):
            return [("gpg.format", "openpgp"), ("user.signingKey", keyID),
                    ("commit.gpgSign", profile.signByDefault ? "true" : "false")]
        case .ssh(let keyPath):
            return [("gpg.format", "ssh"), ("user.signingKey", keyPath),
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

    /// `core.alternateRefsCommand` runs while a fetch looks at a repo's alternates (`objects/info/alternates`,
    /// which a downloaded repo brings along): `true` lists no alternate ref. A submodule fetch would run in a
    /// nested repo with config of its own, and a background fetch has no use for it.
    private static let backgroundFetchConfig: [(String, String)] = [
        ("core.hooksPath", "/dev/null"),
        ("core.fsmonitor", "false"),
        ("core.alternateRefsCommand", "true"),
        ("fetch.recurseSubmodules", "false"),
        ("http.saveCookies", "false"),
        ("gc.auto", "0"),
        ("maintenance.auto", "false"),
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
