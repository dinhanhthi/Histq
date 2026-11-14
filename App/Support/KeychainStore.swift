// Secrets in the Keychain: generic-password items of one service (`AppState.keychainService`), in the file-based
// login keychain (`kSecUseDataProtectionKeychain = false`). Debug and Release are both Developer ID-signed with the
// same identity, so an item one build writes is read by the other without an "Always Allow" prompt (user checklist
// U10.1 checks it). Accounts: `github.<profileID>.<host>` (GitHub tokens), later `ai.<provider>`.
//
// The SecItem calls block (and may wait on a Keychain prompt), so callers run them off the main thread:
// `GitHubTokens` does. Values are never logged or put in an error: only OSStatus codes and account names.
// DEBUG `-HistqKeychain memory` swaps in the in-memory twin, so QA shots never touch a real keychain.
import Foundation
import HistqCore
import Security
import os

/// One Keychain lookup. A failure (a denied prompt, a locked keychain) is never a miss.
enum KeychainRead: Equatable, Sendable {
    case found(Data)
    case notFound
    case failed(OSStatus)
}

/// A failed Keychain write or delete; only the status, never the value.
struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Where items live: the login keychain, or the in-memory twin of QA runs and the DEBUG self-test.
protocol KeychainBackend: Sendable {
    func read(service: String, account: String) -> KeychainRead
    /// Whether the item exists, without reading its data: `errSecSuccess`, `errSecItemNotFound`, or the failure.
    func contains(service: String, account: String) -> OSStatus
    /// Replaces the item's data, or adds the item when it does not exist.
    func upsert(service: String, account: String, data: Data) -> OSStatus
    /// `errSecSuccess` also when there was no such item.
    func delete(service: String, account: String) -> OSStatus
}

/// SecItem calls on generic-password items of the file-based login keychain.
struct LoginKeychainBackend: KeychainBackend {
    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit false: without it a query may also match (or land in) the data protection keychain.
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    func read(service: String, account: String) -> KeychainRead {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecInternalError) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    func contains(service: String, account: String) -> OSStatus {
        // No kSecReturnData: the secret is never decrypted or copied into the process for an existence check.
        var query = query(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    func upsert(service: String, account: String, data: Data) -> OSStatus {
        let query = query(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = query
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    func delete(service: String, account: String) -> OSStatus {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// The in-memory twin: items live as long as the process.
final class InMemoryKeychainBackend: KeychainBackend {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let items = OSAllocatedUnfairLock<[Key: Data]>(initialState: [:])

    func read(service: String, account: String) -> KeychainRead {
        items.withLock { $0[Key(service: service, account: account)] }.map { .found($0) } ?? .notFound
    }

    func contains(service: String, account: String) -> OSStatus {
        items.withLock { $0[Key(service: service, account: account)] != nil } ? errSecSuccess : errSecItemNotFound
    }

    func upsert(service: String, account: String, data: Data) -> OSStatus {
        items.withLock { $0[Key(service: service, account: account)] = data }
        return errSecSuccess
    }

    func delete(service: String, account: String) -> OSStatus {
        items.withLock { $0[Key(service: service, account: account)] = nil }
        return errSecSuccess
    }
}

/// The app's secrets: string values by account in one service. Every call blocks; never call it on the main thread.
struct KeychainStore: Sendable {
    let service: String
    let backend: any KeychainBackend

    /// The app's store: `AppState.keychainService` (the `.qa` service in state-dir mode) in the login keychain, or the
    /// in-memory twin with DEBUG `-HistqKeychain memory`.
    static let shared = KeychainStore(
        service: AppState.keychainService,
        backend: AppState.launchFlag("-HistqKeychain") == "memory" ? InMemoryKeychainBackend() : LoginKeychainBackend())

    /// Whether this is the in-memory twin (DEBUG seams that fake a connected account require it).
    var isInMemory: Bool { backend is InMemoryKeychainBackend }

    /// The account of a profile's GitHub token: `github.<profileID>.<host>`, the id uppercase as `profiles.json` has it
    /// (so `security find-generic-password -a` finds it with the id copied from there).
    static func githubAccount(profileID: UUID, host: String) -> String {
        "github.\(profileID.uuidString).\(host)"
    }

    /// The value, nil when there is no item. Throws `KeychainError` when the read failed, or the item is not UTF-8.
    func string(account: String) throws -> String? {
        assertOffMain()
        switch backend.read(service: service, account: account) {
        case .found(let data):
            guard let value = String(data: data, encoding: .utf8) else { throw KeychainError(status: errSecDecode) }
            return value
        case .notFound:
            return nil
        case .failed(let status):
            throw KeychainError(status: status)
        }
    }

    /// Whether there is an item, its value unread. Throws `KeychainError` when the lookup failed.
    func contains(account: String) throws -> Bool {
        assertOffMain()
        switch backend.contains(service: service, account: account) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case let status: throw KeychainError(status: status)
        }
    }

    func setString(_ value: String, account: String) throws {
        assertOffMain()
        let status = backend.upsert(service: service, account: account, data: Data(value.utf8))
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Deletes the item; no error when there was none.
    func delete(account: String) throws {
        assertOffMain()
        let status = backend.delete(service: service, account: account)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// A Keychain call can wait on a prompt: on the main thread it would freeze the UI.
    private func assertOffMain() {
        assert(!Thread.isMainThread, "Keychain access on the main thread")
    }
}

/// The profiles' GitHub tokens, read from `KeychainStore.shared` off the main thread and cached for the process by
/// account, so a write or fetch reads the Keychain once per profile and host. Settings › Integrations saves and
/// deletes through here, which updates the cache, so the next git command sees the change. A failed read is never
/// cached (the next use tries again).
enum GitHubTokens {
    private static let logger = Logger(subsystem: "com.math2it.histq", category: "keychain")
    /// Account to token; nil = known to have no item.
    private static let cache = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    /// The token of `profileID` for `host`, nil when there is none or the read failed (logged, status only). With
    /// `refresh`, reads the Keychain even when cached (the Integrations page, so an item deleted outside Histq shows).
    @concurrent
    static func token(profileID: UUID, host: String, refresh: Bool = false) async -> String? {
        try? await read(profileID: profileID, host: host, refresh: refresh)
    }

    /// The token git gets for `profile`: nil without a profile or a GitHub account (the Keychain is not read then).
    @concurrent
    static func token(for profile: Profile?) async -> String? {
        guard let profile, let host = profile.github?.host else { return nil }
        return await token(profileID: profile.id, host: host)
    }

    /// As `token(profileID:host:refresh:)`, but a failed read throws instead of reading as no token.
    @concurrent
    static func read(profileID: UUID, host: String, refresh: Bool = false) async throws -> String? {
        let account = KeychainStore.githubAccount(profileID: profileID, host: host)
        if !refresh, let cached = cache.withLock({ $0[account] }) { return cached }
        do {
            let token = try KeychainStore.shared.string(account: account)
            cache.withLock { $0[account] = .some(token) }
            return token
        } catch {
            logger.error("read of \(account, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    @concurrent
    static func save(_ token: String, profileID: UUID, host: String) async throws {
        let account = KeychainStore.githubAccount(profileID: profileID, host: host)
        try KeychainStore.shared.setString(token, account: account)
        cache.withLock { $0[account] = .some(token) }
    }

    @concurrent
    static func delete(profileID: UUID, host: String) async throws {
        let account = KeychainStore.githubAccount(profileID: profileID, host: host)
        // Forgotten first: even if the delete fails, git stops getting the token the user asked to remove.
        cache.withLock { $0[account] = .some(nil) }
        try KeychainStore.shared.delete(account: account)
    }
}

#if DEBUG
/// DEBUG `-HistqKeychainSelfTest memory|login`: a save, read, exists, overwrite and delete round trip against the
/// in-memory twin and, with `login` in state-dir mode, the login keychain under the QA service with a throwaway
/// account that is deleted again. Off the main thread; the outcome (status lines only, never a value) goes to
/// `keychain-selftest.txt` in the state folder. The app has no test target: this checks the real signed app's access.
enum KeychainSelfTest {
    static func runIfAsked() {
        guard let mode = AppState.launchFlag("-HistqKeychainSelfTest") else { return }
        Task.detached(priority: .utility) {
            var lines = ["memory: \(roundTrip(KeychainStore(service: "com.math2it.histq.qa", backend: InMemoryKeychainBackend())))"]
            if mode == "login" {
                // Never the real service: only a state-dir launch has the QA one.
                lines.append(AppState.isStateDirMode
                    ? "login: \(roundTrip(KeychainStore(service: AppState.keychainService, backend: LoginKeychainBackend())))"
                    : "login: skipped (no state dir)")
            }
            let file = StatePaths.root.appending(path: "keychain-selftest.txt", directoryHint: .notDirectory)
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// "ok", or the first step that failed.
    private static func roundTrip(_ store: KeychainStore) -> String {
        let account = "selftest.\(UUID().uuidString.lowercased())"
        let first = UUID().uuidString
        let second = UUID().uuidString
        do {
            guard try store.string(account: account) == nil else { return "fail: item existed before" }
            guard try !store.contains(account: account) else { return "fail: contains before save" }
            try store.setString(first, account: account)
            guard try store.contains(account: account) else { return "fail: contains after save" }
            guard try store.string(account: account) == first else { return "fail: read after save" }
            try store.setString(second, account: account)
            guard try store.string(account: account) == second else { return "fail: read after overwrite" }
            try store.delete(account: account)
            guard try store.string(account: account) == nil else { return "fail: item left after delete" }
            guard try !store.contains(account: account) else { return "fail: contains after delete" }
            try store.delete(account: account)
            return "ok (\(account))"
        } catch {
            try? store.delete(account: account)
            return "fail: \(error)"
        }
    }
}
#endif
