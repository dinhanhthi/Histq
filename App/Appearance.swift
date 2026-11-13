// The app's appearance setting: follow the system, or force dark or light. Dark by default.
import AppKit

/// The appearance the user picks in Settings, stored in UserDefaults under `storageKey`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light

    /// The UserDefaults key, shared with `@AppStorage`. `-AppearanceMode light` on launch overrides it.
    static let storageKey = "AppearanceMode"
    /// The mode before the user picks one.
    static let defaultMode: AppearanceMode = .dark

    /// The stored mode (or a launch argument's), or `defaultMode` if none or unknown.
    static var current: AppearanceMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppearanceMode.init(rawValue:)) ?? defaultMode
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    /// Sets the whole app's appearance; `nil` follows the system.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}
