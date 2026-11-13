// The page of a restored tab whose repo folder is gone (session restore, 8.4): one card that names the folder, with
// Locate… (pick where it went, then it opens in this tab) and Remove (close the tab).
import AppKit
import SwiftUI

struct RepoNotFoundView: View {
    let model: WindowModel
    let tabID: WindowModel.Tab.ID
    let url: URL

    var body: some View {
        ScrollView {
            SectionCard("Repo not found", systemImage: "questionmark.folder") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(url.path)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This folder was moved, renamed or deleted, or it is no longer a git repository.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Locate…") { locate() }
                            .buttonStyle(RowTextButtonStyle(prominent: true))
                        Button("Remove") { remove() }
                            .buttonStyle(RowTextButtonStyle())
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 560)
            .padding(SettingsMetrics.pagePadding)
            .padding(.top, SettingsMetrics.contentTopOffset)
            .frame(maxWidth: .infinity)
        }
    }

    /// A folder picker that starts at the nearest folder that still exists; the folder picked opens in this tab.
    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Locate the repository \(url.lastPathComponent)"
        let model = model
        let tabID = tabID
        let url = url
        Task { @MainActor in
            // The folder checks run off the main thread; the panel shows once they are done (a few `stat` calls).
            panel.directoryURL = await Task.detached { Self.nearestExisting(url) }.value
            guard await panel.begin() == .OK, let picked = panel.url else { return }
            model.locate(tabID, at: picked)
        }
    }

    /// Closes this tab, and the window with its last tab.
    private func remove() {
        if !model.closeTab(id: tabID) { model.closeWindow() }
    }

    /// The deepest parent of `url` that exists, else the home folder.
    private nonisolated static func nearestExisting(_ url: URL) -> URL {
        var folder = url.deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
            folder = folder.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
