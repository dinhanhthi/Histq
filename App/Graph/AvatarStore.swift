// Commit avatars for the graph's nodes, in the mode `PrefKey.avatarMode` names (DEBUG `-HistqAvatarMode` overrides it):
// "real" (Gravatar by the SHA-256 of the email, the GitHub avatar for `@users.noreply.github.com`), "generated" (a
// deterministic pattern and color from the email's hash) or "initials" (monochrome initials).
// `avatar(email:name:pixels:)` never waits: in real mode it returns the generated avatar until the real one is loaded
// (memory, then the disk cache under `StatePaths`, then the network, off the main thread), then posts `didChange` so
// the graphs redraw the rows of that email. A 404 is remembered on disk for 7 days; an offline or failed load keeps
// the generated avatar for the session. Only the hash or the GitHub login leaves the Mac, over https only.
import AppKit
import CryptoKit
import ImageIO
import os

@MainActor
final class AvatarStore {
    static let shared = AvatarStore()

    enum Mode: String {
        case real, generated, initials
    }

    /// Posted on the main thread when avatars change: `userInfo[emailKey]` is the email whose real avatar arrived, or
    /// absent when the mode changed (every node redraws).
    static let didChange = Notification.Name("AvatarStore.didChange")
    static let emailKey = "email"

    private(set) var mode: Mode
    /// Loaded real avatars, by `cacheKey`.
    private let images = NSCache<NSString, NSImage>()
    /// Generated and initials avatars, by kind and identity: resolution-independent drawings.
    private let drawn = NSCache<NSString, NSImage>()
    /// Keys whose real load ended without an image (404, offline, error): they keep the generated avatar this session.
    private var missing: Set<String> = []
    /// Keys being loaded: one request per email and size.
    private var inFlight: Set<String> = []

    private init() {
        mode = Self.resolveMode()
        // Posted for every key, possibly off the main thread; only a change of the resolved mode redraws.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Preferences.defaults, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AvatarStore.shared.preferencesChanged() }
        }
    }

    /// The launch flag, then the preference (registered default "generated"); anything unknown reads as generated.
    /// Real avatars send each author's email hash to gravatar.com, so they are an opt-in (the Phase 7 Appearance
    /// page), never a default.
    private static func resolveMode() -> Mode {
        let value = AppState.launchFlag("-HistqAvatarMode")
            ?? Preferences.defaults.string(forKey: PrefKey.avatarMode.rawValue)
        return value.flatMap(Mode.init(rawValue:)) ?? .generated
    }

    private func preferencesChanged() {
        let resolved = Self.resolveMode()
        guard resolved != mode else { return }
        mode = resolved
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The avatar to draw now for an author: `pixels` is the node's diameter in device pixels (the size real avatars
    /// are fetched at). Never blocks; in real mode a missing avatar starts its load and the generated one stands in.
    func avatar(email: String, name: String, pixels: Int) -> NSImage? {
        let identity = Self.identity(email: email, name: name)
        switch mode {
        case .initials:
            return initialsAvatar(name: name)
        case .generated:
            return generatedAvatar(identity: identity)
        case .real:
            let key = "\(identity)|\(pixels)" as String
            if let image = images.object(forKey: key as NSString) { return image }
            if !missing.contains(key), !email.isEmpty { load(identity: identity, key: key, pixels: pixels) }
            return generatedAvatar(identity: identity)
        }
    }

    /// The trimmed, lowercased email (the name when there is none): what the hash, the caches and the files use.
    private static func identity(email: String, name: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "name:" + name : trimmed
    }

    // MARK: Real avatars

    private func load(identity: String, key: String, pixels: Int) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let image = await AvatarLoader.load(identity: identity, pixels: pixels)
            await MainActor.run {
                AvatarStore.shared.loaded(key: key, identity: identity, image: image)
            }
        }
    }

    private func loaded(key: String, identity: String, image: AvatarLoader.Decoded?) {
        inFlight.remove(key)
        guard let image else {
            // Resolved for the session: the generated avatar already on screen stays, nothing redraws.
            missing.insert(key)
            return
        }
        let size = NSSize(width: image.cgImage.width, height: image.cgImage.height)
        images.setObject(NSImage(cgImage: image.cgImage, size: size), forKey: key as NSString)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.emailKey: identity])
    }

    /// Whether `email` is the identity `didChange` named (the graph compares its rows' emails with it).
    static func matches(email: String, name: String, changed: String) -> Bool {
        identity(email: email, name: name) == changed
    }

    // MARK: Generated and initials avatars

    /// A 5x5 mirrored pattern in one of the lane colors on a dark disc, from the identity's SHA-256. Opaque, so the
    /// node's lane fill does not show through.
    private func generatedAvatar(identity: String) -> NSImage {
        let cacheKey = "g|\(identity)" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        let hash = Array(SHA256.hash(data: Data(identity.utf8)))
        let lanes = Palette.graphLanes
        let color = lanes[Int(hash[0]) % lanes.count]
        // Bits 0..<15 of bytes 1...2 pick the cells of the 3 left columns; the right 2 mirror them.
        let bits = UInt32(hash[1]) | UInt32(hash[2]) << 8
        let background = Self.background
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            background.setFill()
            rect.fill()
            color.setFill()
            let inset = rect.width * 0.18
            let cell = (rect.width - 2 * inset) / 5
            for column in 0..<3 {
                for row in 0..<5 where bits & (1 << UInt32(column * 5 + row)) != 0 {
                    for x in Set([column, 4 - column]) {
                        NSRect(x: rect.minX + inset + CGFloat(x) * cell, y: rect.minY + inset + CGFloat(row) * cell,
                               width: cell, height: cell).fill()
                    }
                }
            }
            return true
        }
        drawn.setObject(image, forKey: cacheKey)
        return image
    }

    /// The author's initials, light on a neutral disc: the same for every author and lane (the lane ring stays).
    private func initialsAvatar(name: String) -> NSImage {
        let initials = GraphRowDrawing.initials(of: name)
        let cacheKey = "i|\(initials)" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        let fill = Self.initialsFill
        let textColor = Self.initialsText
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            fill.setFill()
            rect.fill()
            guard !initials.isEmpty else { return true }
            let font = NSFont.systemFont(ofSize: (rect.height * 0.46).rounded(), weight: .semibold)
            let text = NSAttributedString(
                string: initials, attributes: [.font: font, .foregroundColor: textColor])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        drawn.setObject(image, forKey: cacheKey)
        return image
    }

    /// The generated avatar's background: darker than the card so the pattern stands out. #1C1C1E
    private static let background = NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    /// The initials avatar's disc and letters. #48484A, white 0.92
    private static let initialsFill = NSColor(srgbRed: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255, alpha: 1)
    private static let initialsText = NSColor.white.withAlphaComponent(0.92)
}

/// The off-main half of real avatars: disk cache, network, decoding. Holds no state of its own beyond the session.
private enum AvatarLoader {
    /// A decoded avatar. CGImage is immutable, so crossing to the main actor is safe.
    struct Decoded: @unchecked Sendable {
        let cgImage: CGImage
    }

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "avatars")
    /// Larger downloads are ignored.
    private static let maxBytes = 1_000_000
    /// How long a 404 is believed.
    private static let notFoundTTL: TimeInterval = 7 * 24 * 3600

    /// Created on first use, off the main thread (`StatePaths.directory` creates the folder).
    private static let directory: URL = StatePaths.directory("Avatars")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: HTTPSOnly(), delegateQueue: nil)
    }()

    /// The disk cache, then the network. nil: use the generated avatar.
    static func load(identity: String, pixels: Int) async -> Decoded? {
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(path: "\(hash)-\(pixels).img")
        let marker = directory.appending(path: "\(hash).404")
        let fileManager = FileManager.default

        if let data = try? Data(contentsOf: file), let image = decode(data, pixels: pixels) {
            return image
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: marker.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < notFoundTTL
        {
            return nil
        }
        guard !identity.hasPrefix("name:"), let url = url(identity: identity, hash: hash, pixels: pixels) else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 {
                fileManager.createFile(atPath: marker.path, contents: nil)
                return nil
            }
            guard http.statusCode == 200, http.expectedContentLength <= maxBytes, data.count <= maxBytes,
                  let image = decode(data, pixels: pixels)
            else { return nil }
            try? data.write(to: file, options: .atomic)
            try? fileManager.removeItem(at: marker)
            return image
        } catch {
            logger.debug("avatar load failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Gravatar by hash, or the GitHub avatar for a noreply address (`<id>+<login>@` or `<login>@`). nil when a
    /// GitHub address has neither a valid id nor a valid login.
    static func url(identity: String, hash: String, pixels: Int) -> URL? {
        let suffix = "@users.noreply.github.com"
        guard identity.hasSuffix(suffix) else {
            return URL(string: "https://gravatar.com/avatar/\(hash)?s=\(pixels)&d=404")
        }
        let local = identity.dropLast(suffix.count)
        var id: Substring?
        var login = local
        if let plus = local.firstIndex(of: "+") {
            id = local[..<plus]
            login = local[local.index(after: plus)...]
        }
        if let id, (1...20).contains(id.count), id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) {
            return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(pixels)")
        }
        guard isValidLogin(login) else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(login)?s=\(pixels)")
    }

    /// `[A-Za-z0-9-]{1,39}`.
    private static func isValidLogin(_ login: Substring) -> Bool {
        (1...39).contains(login.count)
            && login.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// Decodes at most `pixels` on the longer side, fully decoded here so the main thread only draws it.
    private static func decode(_ data: Data, pixels: Int) -> Decoded? {
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, pixels),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Decoded(cgImage: image)
    }
}

/// Follows a redirect only to another https URL.
private final class HTTPSOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}
