// Security tests for SSHKeyGenerator (task 7.2), with the real /usr/bin/ssh-keygen writing into a temp folder,
// never ~/.ssh: an existing private or public key file is never replaced; an option-looking or multi-line comment
// or path is rejected before ssh-keygen runs; a new pair has its private key at mode 600.
import Foundation
import HistqCore
import Testing

struct SSHKeyGeneratorTests {
    /// A temp folder with its own HOME and an environment whose PATH finds the system ssh-keygen.
    struct Sandbox {
        let folder: URL
        let generator: SSHKeyGenerator

        init() throws {
            folder = try Fixtures.makeTempDirectory("HistqSSHKey")
            let home = folder.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            generator = SSHKeyGenerator(environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": folder.path])
        }

        func key(_ name: String) -> URL { folder.appending(path: "keys/\(name)") }

        func remove() { Fixtures.removeTempDirectory(folder) }
    }

    @Test("an existing private key, public key or dangling symlink is never replaced")
    func refusesToOverwrite() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let keys = sandbox.folder.appending(path: "keys", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        let old = Data("old key\n".utf8)

        let privateKey = sandbox.key("private-exists")
        try old.write(to: privateKey)
        await #expect(throws: SSHKeyGenerator.GenerateError.keyExists(path: privateKey.path)) {
            try await sandbox.generator.generate(privateKey: privateKey, comment: "me@histq.invalid")
        }
        #expect(FileManager.default.contents(atPath: privateKey.path) == old)
        #expect(!FileManager.default.fileExists(atPath: privateKey.path + ".pub"))

        let pubOnly = sandbox.key("pub-exists")
        try old.write(to: URL(filePath: pubOnly.path + ".pub"))
        await #expect(throws: SSHKeyGenerator.GenerateError.keyExists(path: pubOnly.path + ".pub")) {
            try await sandbox.generator.generate(privateKey: pubOnly, comment: "me@histq.invalid")
        }
        #expect(FileManager.default.contents(atPath: pubOnly.path + ".pub") == old)
        #expect(!FileManager.default.fileExists(atPath: pubOnly.path))

        let link = sandbox.key("dangling")
        let target = sandbox.folder.appending(path: "outside-target")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        await #expect(throws: SSHKeyGenerator.GenerateError.keyExists(path: link.path)) {
            try await sandbox.generator.generate(privateKey: link, comment: "me@histq.invalid")
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("an option-looking or multi-line comment or path is rejected before ssh-keygen runs")
    func unsafeInputRejected() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let key = sandbox.key("id_ed25519")
        for comment in ["-N", "-oProxyCommand=x", "me@histq.invalid\nssh-ed25519 AAAA evil", "a\rb", "a\u{0}b"] {
            await #expect(throws: SSHKeyGenerator.GenerateError.invalidComment(comment)) {
                try await sandbox.generator.generate(privateKey: key, comment: comment)
            }
        }
        for path in [sandbox.folder.path + "/-f", sandbox.folder.path + "/-N", sandbox.folder.path + "/a\nb", sandbox.folder.path + "/"] {
            await #expect(throws: SSHKeyGenerator.GenerateError.invalidPath(path)) {
                try await sandbox.generator.generate(privateKey: URL(filePath: path), comment: "me@histq.invalid")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder.appending(path: "keys").path), "nothing ran")
    }

    @Test("generates an ed25519 pair with the private key at mode 600 and returns the public key")
    func createsKeyPair() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let key = sandbox.key("id_ed25519_work")
        let publicKey = try await sandbox.generator.generate(privateKey: key, comment: "me@histq.invalid")

        #expect(publicKey.hasPrefix("ssh-ed25519 ") && publicKey.hasSuffix(" me@histq.invalid"))
        let written = try String(contentsOf: URL(filePath: key.path + ".pub"), encoding: .utf8)
        #expect(written.trimmingCharacters(in: .newlines) == publicKey)
        let mode = try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: key.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
    }
}
