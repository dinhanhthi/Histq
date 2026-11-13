// Settings › Appearance: the commit graph's avatars, date format and row height. No theme choice: Histq is dark
// only. The graph and `AvatarStore` read these keys and update open tabs at once.
import SwiftUI

struct AppearanceSettings: View {
    @AppStorage(PrefKey.avatarMode.rawValue, store: Preferences.defaults) private var avatarMode = "generated"
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults) private var rowDensity = "regular"

    /// The date formats offered, the shortest (the default, 24 h) first; a format set by hand (`defaults write`) is
    /// listed too.
    private static let dateFormats = [
        "MM/dd/yy @ HH:mm", "MM/dd/yyyy @ h:mm a", "dd/MM/yyyy HH:mm", "yyyy-MM-dd HH:mm", "MMM d, yyyy h:mm a",
        "d MMM yyyy HH:mm",
    ]

    var body: some View {
        SettingsPageGate(section: .appearance, isLoaded: true) {
            SettingsGroup("Avatars") {
                LabeledContent {
                    CapsuleTabs(selection: $avatarMode, tabs: ["generated", "real", "initials"],
                                title: { Text(Self.avatarTitle($0)) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Commit avatars")
                    SettingsHint("Generated: a pattern from each author's email, drawn on this Mac.")
                }
                SettingsDivider()
                Label {
                    Text("Real avatars send each author's email hash to gravatar.com, and GitHub logins to GitHub, "
                        + "to download their pictures.")
                        .font(.settingsCaption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: avatarMode == "real" ? "exclamationmark.triangle" : "info.circle")
                }
                .foregroundStyle(.secondary)
            }
            SettingsGroup("Commit list") {
                LabeledContent {
                    CapsuleMenuPicker(label: "Date format", selection: $dateFormat,
                                      title: Text(Self.sample(dateFormat))) {
                        ForEach(formats, id: \.self) { format in
                            Text(Self.sample(format)).tag(format)
                        }
                    }
                } label: {
                    Text("Date format")
                    SettingsHint("The commit list's Date column.")
                }
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $rowDensity, tabs: ["compact", "regular", "comfortable"],
                                title: { Text($0.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Row height")
                    SettingsHint("Compact fits more commits on screen.")
                }
            }
        } skeleton: {
            EmptyView()
        }
    }

    private var formats: [String] {
        Self.dateFormats.contains(dateFormat) ? Self.dateFormats : Self.dateFormats + [dateFormat]
    }

    private static func avatarTitle(_ mode: String) -> String {
        switch mode {
        case "real": "Real"
        case "initials": "Initials"
        default: "Generated"
        }
    }

    /// Today's date in `format`, as the menu shows it.
    private static func sample(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: .now)
    }
}
