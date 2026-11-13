// The toolbar's profile chip, after the branch menu: the selected tab's profile name with its color dot, and the menu
// that switches the tab to another profile. The chip is a native `NSMenuToolbarItem` of `HeaderToolbar` (never a
// SwiftUI `.toolbar`); this file holds what it shows and what its menu lists.
import AppKit
import HistqCore
import SwiftUI

@MainActor
enum ProfilePicker {
    /// What the chip and the menu call "no profile": git then uses the user's own config.
    static let noneTitle = "No Profile"

    /// The chip's title: the profile's name, or `noneTitle`.
    static func title(_ profile: Profile?) -> String {
        guard let profile else { return noneTitle }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Unnamed Profile" : name
    }

    /// The chip's tooltip: who the tab's commits are made as.
    static func toolTip(_ profile: Profile?) -> String {
        guard let profile else { return "Commits use your own git config. Click to pick a profile." }
        let email = profile.identity.email.isEmpty ? "" : " <\(profile.identity.email)>"
        return "Commits in this tab are made as \(profile.identity.name)\(email). Click to switch profiles."
    }

    /// A dot in the profile color (`#RRGGBB`), or a hollow ring for no profile. Not a template image, so the toolbar
    /// keeps its color.
    static func dot(hex: String?) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = rect.insetBy(dx: 1, dy: 1)
            if let hex {
                NSColor(ProfileColors.color(hex)).setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else {
                // Drawn at display time, so the ring follows the appearance's secondary label color.
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                NSColor.secondaryLabelColor.setStroke()
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = hex == nil ? noneTitle : "Profile color"
        return image
    }

    /// The menu: every profile (the tab's checked), "None (your git config)", then "Edit Profiles…", which opens
    /// Settings › Profiles. A pick switches the tab at once (`RepoSession.setProfile`).
    static func entries(session: RepoSession, model: WindowModel) -> [MenuEntry] {
        let library = ProfileLibrary.shared
        let current = session.profile?.id
        var entries: [MenuEntry] = []
        switch library.state {
        case .loaded(let store):
            entries = store.profiles.map { profile in
                .action(title(profile), checked: profile.id == current) { [weak session] in
                    session?.setProfile(profile.id)
                }
            }
        case .failed:
            entries = [.action("Profiles could not be read", enabled: false) {}]
        case .idle, .loading:
            entries = [.action("Loading profiles…", enabled: false) {}]
        }
        entries += [
            .separator,
            .action("None (your git config)", checked: current == nil) { [weak session] in session?.setProfile(nil) },
            .separator,
            .action("Edit Profiles…") { [weak model] in model?.selectSettings(.profiles) },
        ]
        return entries
    }

    /// Puts each profile's dot before its item (`MenuEntry` has no image); the profiles are the menu's first items.
    static func decorate(_ menu: NSMenu) {
        guard let profiles = ProfileLibrary.shared.store?.profiles else { return }
        for (item, profile) in zip(menu.items, profiles) where !item.isSeparatorItem {
            item.image = dot(hex: profile.color)
        }
    }
}
