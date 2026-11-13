// A profile is who Histq acts as in one tab: the commit identity, optional signing, the SSH key and the
// GitHub account. It is injected into each git process (see `GitInvocation`); `.git/config` is never
// edited. It holds no secrets: tokens live in the Keychain, keys stay where they are on disk.
import Foundation

public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public struct Identity: Codable, Sendable, Equatable {
        public var name: String
        public var email: String

        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }
    }

    public enum Signing: Codable, Sendable, Equatable {
        case none
        /// An OpenPGP key ID or fingerprint, used with the user's `gpg`.
        case gpg(keyID: String)
        /// A path to an SSH key (private, or public when the agent holds the private key).
        case ssh(keyPath: String)
    }

    public enum SSHKey: Codable, Sendable, Equatable {
        /// Whatever keys the SSH agent (and `~/.ssh/config`) offer.
        case agent
        /// This private key only (`-i <path> -o IdentitiesOnly=yes`).
        case keyFile(path: String)
    }

    public struct GitHubAccount: Codable, Sendable, Equatable {
        public var host: String
        public var login: String

        public init(host: String = "github.com", login: String) {
            self.host = host
            self.login = login
        }
    }

    public var id: UUID
    public var name: String
    /// A `#RRGGBB` color for the profile's badge.
    public var color: String
    public var identity: Identity
    public var signing: Signing
    /// Sign new commits without being asked (only meaningful when `signing` is not `.none`).
    public var signByDefault: Bool
    public var ssh: SSHKey
    public var github: GitHubAccount?

    public init(
        id: UUID = UUID(), name: String, color: String, identity: Identity, signing: Signing = .none,
        signByDefault: Bool = false, ssh: SSHKey = .agent, github: GitHubAccount? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.identity = identity
        self.signing = signing
        self.signByDefault = signByDefault
        self.ssh = ssh
        self.github = github
    }
}
