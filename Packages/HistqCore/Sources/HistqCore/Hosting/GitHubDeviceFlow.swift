// GitHub's OAuth device flow (RFC 8628): `start()` asks `https://<host>/login/device/code` for a user code the
// user types at the verification URL, then `waitForToken(_:)` polls `https://<host>/login/oauth/access_token`
// until the user approves. The endpoints live on the web host, not the API host, and report the flow's states as
// `error` codes in a 200 answer: `authorization_pending` (poll again), `slow_down` (wait 5 s longer from now on),
// `expired_token` and `access_denied`. The wait is an injected `sleep`, so tests never wait, and the time slept
// counts against the code's `expires_in` so a flow cannot poll forever.
import Foundation

public struct GitHubDeviceFlow: Sendable {
    /// What `start()` returns: show `userCode` and open `verificationURI`.
    public struct DeviceCode: Sendable, Equatable, Decodable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: String
        /// Seconds until the codes expire.
        public var expiresIn: Int
        /// Seconds to wait between polls.
        public var interval: Int

        public init(deviceCode: String, userCode: String, verificationURI: String, expiresIn: Int, interval: Int) {
            self.deviceCode = deviceCode
            self.userCode = userCode
            self.verificationURI = verificationURI
            self.expiresIn = expiresIn
            self.interval = interval
        }

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    public enum DeviceFlowError: Error, Equatable, Sendable, CustomStringConvertible {
        /// No OAuth App client ID (`HistqGitHubClientID` is empty).
        case missingClientID
        /// The user did not enter the code in time.
        case expired
        /// The user pressed Cancel on GitHub.
        case accessDenied
        /// Any other OAuth error code (`device_flow_disabled`, `incorrect_client_credentials`...).
        case failed(code: String, description: String?)

        public var description: String {
            switch self {
            case .missingClientID: "No GitHub OAuth App client ID is set."
            case .expired: "The code expired before it was entered. Start again."
            case .accessDenied: "The authorization was cancelled on GitHub."
            case .failed(let code, let description): "GitHub sign-in failed (\(code))" + (description.map { ": \($0)" } ?? ".")
            }
        }
    }

    public let host: String
    public let clientID: String
    public let scopes: [String]
    private let webBase: URL
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `scopes`: `repo` for private repositories and HTTPS pushes, `read:org` for organization repositories,
    /// `workflow` because GitHub refuses a push that changes `.github/workflows` without it. Throws
    /// `GitHubError.invalidHost` or `DeviceFlowError.missingClientID`.
    public init(
        host: String = "github.com", clientID: String, scopes: [String] = ["repo", "read:org", "workflow"],
        session: URLSession = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        guard let validHost = GitHubClient.validatedHost(host), let webBase = URL(string: "https://\(validHost)") else {
            throw GitHubError.invalidHost(host)
        }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceFlowError.missingClientID
        }
        self.host = validHost
        self.clientID = clientID
        self.scopes = scopes
        self.webBase = webBase
        self.session = session
        self.sleep = sleep
    }

    /// Asks for a device code and a user code.
    public func start() async throws -> DeviceCode {
        let data = try await post(["login", "device", "code"], ["client_id": clientID, "scope": scopes.joined(separator: " ")])
        if let failure = try? GitHubHTTP.decode(data) as Answer, let code = failure.error {
            throw DeviceFlowError.failed(code: code, description: failure.errorDescription)
        }
        return try GitHubHTTP.decode(data)
    }

    /// Polls until the user approves and returns the access token. Throws `DeviceFlowError.expired`,
    /// `.accessDenied` or `.failed`, a `GitHubError` for an HTTP failure, or `CancellationError`.
    public func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 1)
        var waited = 0
        while true {
            guard waited < code.expiresIn else { throw DeviceFlowError.expired }
            try await sleep(.seconds(interval))
            waited += interval
            try Task.checkCancellation()
            let data = try await post(["login", "oauth", "access_token"], [
                "client_id": clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let answer: Answer = try GitHubHTTP.decode(data)
            if let token = answer.accessToken {
                guard GitHubClient.isUsableToken(token) else { throw GitHubError.invalidResponse("an unusable token") }
                return token
            }
            switch answer.error {
            case "authorization_pending":
                continue
            case "slow_down":
                // Every later poll waits 5 s longer; GitHub may also say the new interval itself.
                interval = max(interval + 5, answer.interval ?? 0)
            case "expired_token":
                throw DeviceFlowError.expired
            case "access_denied":
                throw DeviceFlowError.accessDenied
            case let code?:
                throw DeviceFlowError.failed(code: code, description: answer.errorDescription)
            case nil:
                throw GitHubError.invalidResponse("neither a token nor an error")
            }
        }
    }

    /// The token endpoint's answer: a token, or an OAuth error code (with a new `interval` for `slow_down`).
    private struct Answer: Decodable {
        var accessToken: String?
        var error: String?
        var errorDescription: String?
        var interval: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
            case interval
        }
    }

    /// A form POST asking for JSON. An HTTP failure without an OAuth error code becomes a `GitHubError`.
    private func post(_ segments: [String], _ form: [String: String]) async throws -> Data {
        var url = webBase
        for segment in segments { url.append(path: segment) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Histq", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.formEncoded(form).utf8)
        let (data, response) = try await GitHubHTTP.load(request, session: session)
        if !(200..<300).contains(response.statusCode) {
            let answer = try? GitHubHTTP.decode(data) as Answer
            if let code = answer?.error { throw DeviceFlowError.failed(code: code, description: answer?.errorDescription) }
            throw GitHubHTTP.error(for: response, data: data)
        }
        return data
    }

    /// `application/x-www-form-urlencoded` with only unreserved characters left as they are.
    static func formEncoded(_ form: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return form.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }
}
