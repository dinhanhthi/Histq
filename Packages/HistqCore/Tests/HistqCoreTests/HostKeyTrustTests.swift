// Security tests for HostKeyTrust (task 3.4), with a fake `ssh-keyscan` first on PATH (it prints keys made
// by the real `ssh-keygen` for a throwaway key, plus a comment and junk) and a temp known_hosts, never the
// network or the user's ~/.ssh: option-looking and whitespace hosts are rejected before anything runs;
// `trust` appends exactly the scanned lines and leaves existing bytes identical; nothing is written before
// `trust` is called.
import Foundation
import HistqCore
import Testing

struct HostKeyTrustTests {
    /// A temp folder with a fake ssh-keyscan, the keys it prints and the environment that finds it.
    struct Fake {
        let folder: URL
        let trust: HostKeyTrust
        /// The `<host> <type> <base64>` lines the fake prints for `[example.com]:2222`.
        let lines: [String]
        let argsFile: URL

        init() async throws {
            folder = try Fixtures.makeTempDirectory("HistqHostKey")
            let home = folder.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let env = [
                "PATH": folder.appending(path: "bin").path + ":/usr/bin:/bin", "HOME": home.path,
                "TMPDIR": folder.path,
            ]
            var lines: [String] = []
            for type in ["ed25519", "ecdsa"] {
                let key = folder.appending(path: "key-\(type)")
                _ = try await GitRunner(executable: URL(filePath: "/usr/bin/ssh-keygen")).run(
                    ["-q", "-t", type, "-N", "", "-C", "", "-f", key.path], cwd: folder, env: env, timeout: .seconds(30))
                let pub = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
                let fields = pub.split(separator: " ")
                lines.append("[example.com]:2222 \(fields[0]) \(fields[1])")
            }
            self.lines = lines
            argsFile = folder.appending(path: "keyscan-args")
            let output = folder.appending(path: "keyscan-output")
            let printed = ["# example.com:2222 SSH-2.0-OpenSSH_9.9", lines[0], "evil.example ssh-ed25519 AAAA",
                           "[example.com]:2222 ssh-dss AAAA", lines[1], "not a key line at all"]
            try Data((printed.joined(separator: "\n") + "\n").utf8).write(to: output)
            try Fixtures.writeScript(
                "printf '%s\\n' \"$@\" > '\(argsFile.path)'\ncat '\(output.path)'",
                to: folder.appending(path: "bin/ssh-keyscan"))
            trust = HostKeyTrust(environment: env)
        }

        var scannerRan: Bool { FileManager.default.fileExists(atPath: argsFile.path) }

        func remove() { Fixtures.removeTempDirectory(folder) }
    }

    @Test("a host starting with - or containing whitespace is rejected before ssh-keyscan runs")
    func optionAndWhitespaceHostsRejected() async throws {
        let fx = try await Fake()
        defer { fx.remove() }
        for name in ["-oProxyCommand=touch /tmp/pwned", "-p", "example.com evil.com", "exa\tmple.com", "a\nb", "",
                     "evil.com,example.com", "*", "h?st", "!evil.com", "[x]", "a|b", "git@example.com"] {
            await #expect(throws: HostKeyTrust.TrustError.invalidHost(name)) {
                try await fx.trust.scan(HostKeyTrust.Host(name: name))
            }
        }
        #expect(!fx.scannerRan)
        // The host from a remote URL is checked the same way.
        let fromURL = try #require(HostKeyTrust.host(fromRemoteURL: "-oProxyCommand=x:repo.git"))
        await #expect(throws: HostKeyTrust.TrustError.self) { try await fx.trust.scan(fromURL) }
        #expect(!fx.scannerRan)
    }

    @Test("trust appends exactly the scanned lines and leaves existing lines byte-identical")
    func trustAppendsOnlyScannedLines() async throws {
        let fx = try await Fake()
        defer { fx.remove() }
        let error = GitError.hostKey(
            exit: 128,
            stderrTail: "No ED25519 host key is known for [example.com]:2222 and you have requested strict checking.\r\n"
                + "Host key verification failed.\r\nfatal: Could not read from remote repository.\n")
        let host = try #require(HostKeyTrust.host(from: error))
        #expect(host == HostKeyTrust.Host(name: "example.com", port: 2222))
        #expect(HostKeyTrust.host(fromRemoteURL: "ssh://git@example.com:2222/team/repo.git") == host)

        let knownHosts = fx.folder.appending(path: "ssh/known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        // No final newline, a comment and a hashed entry: all must stay as they are.
        let existing = Data("|1|abc=|def= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExisting\n# keep me\nold.example ssh-rsa AAAAB3Nza".utf8)
        try existing.write(to: knownHosts)

        let scan = try await fx.trust.scan(host)
        #expect(try String(contentsOf: fx.argsFile, encoding: .utf8)
            == "-T\n5\n-p\n2222\n-t\ned25519,ecdsa,rsa\n--\nexample.com\n")
        #expect(scan.keys.map(\.line) == fx.lines)
        #expect(scan.keys.map(\.type) == ["ssh-ed25519", "ecdsa-sha2-nistp256"])
        #expect(scan.keys.allSatisfy { $0.fingerprint.hasPrefix("SHA256:") && $0.fingerprint.count > 40 })
        #expect(try Data(contentsOf: knownHosts) == existing, "scan writes nothing")

        try fx.trust.trust(scan, knownHosts: knownHosts)
        let after = try Data(contentsOf: knownHosts)
        #expect(after == existing + Data(("\n" + fx.lines.joined(separator: "\n") + "\n").utf8))
        #expect(after.prefix(existing.count) == existing)
    }

    @Test("nothing is written before trust; trust creates a missing known_hosts with mode 600")
    func nothingWrittenBeforeTrust() async throws {
        let fx = try await Fake()
        defer { fx.remove() }
        let knownHosts = fx.folder.appending(path: "new-ssh/known_hosts")
        let scan = try await fx.trust.scan(HostKeyTrust.Host(name: "example.com", port: 2222))
        #expect(fx.scannerRan)
        #expect(!FileManager.default.fileExists(atPath: knownHosts.deletingLastPathComponent().path))

        try fx.trust.trust(scan, knownHosts: knownHosts)
        #expect(try Data(contentsOf: knownHosts) == Data((fx.lines.joined(separator: "\n") + "\n").utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: knownHosts.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
