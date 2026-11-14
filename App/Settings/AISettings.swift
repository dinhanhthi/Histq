// Settings › AI: the provider the AI buttons use (Generate Message, Explain, Suggest Resolution), its API key, model
// and, for a custom OpenAI-compatible server, its base URL, plus "Test connection". The key goes only into the login
// Keychain (account `ai.<provider>`, `AIKeys`): the field is cleared once saved and the page then shows "••• saved",
// never the key. Nothing is sent to a provider until the user clicks Test connection or an AI button.
import HistqCore
import SwiftUI
import os

/// The providers' API keys in `KeychainStore.shared`, account `ai.<provider raw value>`. Every call runs off the main
/// thread (a Keychain call can wait on a prompt). Keys are never logged or put in an error: only account names and
/// OSStatus codes.
enum AIKeys {
    private static let logger = Logger(subsystem: "com.math2it.histq", category: "keychain")

    static func account(_ provider: AIProvider) -> String { "ai.\(provider.rawValue)" }

    /// The key, nil when there is none. Throws `KeychainError` when the read failed.
    @concurrent
    static func key(for provider: AIProvider) async throws -> String? {
        do {
            return try KeychainStore.shared.string(account: account(provider))
        } catch {
            logger.error("read of \(account(provider), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Which providers have a key, checked without reading the keys (Save never stores an empty one); a provider
    /// whose lookup failed is left out (unknown, so not set up).
    @concurrent
    static func presence() async -> [AIProvider: Bool] {
        var stored: [AIProvider: Bool] = [:]
        for provider in AIProvider.allCases {
            do {
                stored[provider] = try KeychainStore.shared.contains(account: account(provider))
            } catch {
                logger.error("lookup of \(account(provider), privacy: .public) failed: \(String(describing: error), privacy: .public)")
                continue
            }
        }
        return stored
    }

    @concurrent
    static func save(_ key: String, for provider: AIProvider) async throws {
        try KeychainStore.shared.setString(key, account: account(provider))
    }

    @concurrent
    static func delete(for provider: AIProvider) async throws {
        try KeychainStore.shared.delete(account: account(provider))
    }
}

/// The AI settings the hooks and the Settings page share: the active provider, each provider's model, the custom base
/// URL (all in `Preferences.defaults`) and whether each provider's key is in the Keychain (read off the main thread
/// once, then updated by Save and Remove). The hooks are enabled only while `isReady`.
@Observable
@MainActor
final class AISetup {
    static let shared = AISetup()

    /// The hooks' tooltip while the active provider is not set up.
    static let setUpHint = "Set up an AI provider in Settings › AI"

    private(set) var provider: AIProvider
    private(set) var models: [String: String]
    private(set) var customBaseURL: String
    /// Whether each provider's key is in the Keychain; a provider missing here is not read yet, or its read failed.
    private(set) var keyStored: [AIProvider: Bool] = [:]
    /// The first Keychain read has finished.
    private(set) var keysLoaded = false
    private var loadTask: Task<Void, Never>?

    private init() {
        let defaults = Preferences.defaults
        provider = defaults.string(forKey: PrefKey.aiProvider.rawValue).flatMap(AIProvider.init(rawValue:)) ?? .openAI
        models = defaults.dictionary(forKey: PrefKey.aiModels.rawValue) as? [String: String] ?? [:]
        customBaseURL = defaults.string(forKey: PrefKey.aiCustomBaseURL.rawValue) ?? ""
    }

    func setProvider(_ provider: AIProvider) {
        self.provider = provider
        Preferences.defaults.set(provider.rawValue, forKey: PrefKey.aiProvider.rawValue)
    }

    /// The model typed for `provider` (trimmed), else its default; empty for a custom server without one.
    func model(for provider: AIProvider) -> String {
        let typed = (models[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? provider.defaultModel : typed
    }

    /// The model field's text (empty = the default).
    func typedModel(for provider: AIProvider) -> String { models[provider.rawValue] ?? "" }

    func setTypedModel(_ text: String, for provider: AIProvider) {
        models[provider.rawValue] = text
        Preferences.defaults.set(models, forKey: PrefKey.aiModels.rawValue)
    }

    func setCustomBaseURL(_ text: String) {
        customBaseURL = text
        Preferences.defaults.set(text, forKey: PrefKey.aiCustomBaseURL.rawValue)
    }

    /// Why the custom base URL cannot be used; nil when it normalizes.
    var customURLError: AIEndpointError? {
        do {
            _ = try AIEndpoint.normalize(customBaseURL)
            return nil
        } catch {
            return error
        }
    }

    /// Why `provider` cannot be used yet; nil when it can. A built-in provider needs its key; a custom server needs a
    /// valid base URL (its key is optional, many local servers take none) and a model, which has no default there.
    func setupProblem(_ provider: AIProvider) -> String? {
        if provider == .custom {
            if let customURLError { return customURLError.description }
        } else if keyStored[provider] != true {
            return keysLoaded ? "Add an API key." : "Reading the Keychain…"
        }
        return model(for: provider).isEmpty ? "Enter a model." : nil
    }

    /// The active provider can be used: the AI buttons are enabled.
    var isReady: Bool { setupProblem(provider) == nil }

    /// Reads which providers have a key, once (off the main thread). The AI buttons call it when they appear.
    func loadKeysIfNeeded() {
        guard loadTask == nil else { return }
        reloadKeys()
    }

    /// Reads the keys' presence again (each select of the Settings page, so an item removed outside Histq shows).
    func reloadKeys() {
        loadTask?.cancel()
        loadTask = Task {
            #if DEBUG
            await AIStub.seedKeysIfNeeded()
            #endif
            let stored = await AIKeys.presence()
            guard !Task.isCancelled else { return }
            keyStored = stored
            keysLoaded = true
            #if DEBUG
            AIStub.log("keys read: \(provider.rawValue) ready \(isReady) problem \(setupProblem(provider) ?? "none")")
            #endif
        }
    }

    /// Checks and saves a key typed for `provider`. Throws `AIClientError.invalidAPIKey` for a key with spaces or
    /// other characters a key never has, `KeychainError` when the save failed.
    func saveKey(_ raw: String, for provider: AIProvider) async throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIChatClient.isUsableAPIKey(key) else { throw AIClientError.invalidAPIKey }
        try await AIKeys.save(key, for: provider)
        keyStored[provider] = true
    }

    func removeKey(for provider: AIProvider) async throws {
        // Forgotten first: even if the delete fails, the buttons stop using the key the user asked to remove.
        keyStored[provider] = false
        try await AIKeys.delete(for: provider)
    }

    /// The client of `provider` with its key (read off the main thread here, never kept), its fixed base URL or the
    /// custom one. In a DEBUG `-HistqAIStub` run its session is the stub's, which never reaches the network.
    func makeClient(for provider: AIProvider) async throws -> AIChatClient {
        let key = try await AIKeys.key(for: provider)
        #if DEBUG
        let session = AIStub.isEnabled ? AIStub.session : URLSession.shared
        #else
        let session = URLSession.shared
        #endif
        return try AIChatClient(provider: provider, apiKey: key, customBaseURL: customBaseURL, session: session)
    }
}

struct AISettings: View {
    @Environment(WindowModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyBusy = false
    @State private var keyError: String?
    @State private var test: TestState = .idle
    @State private var testTask: Task<Void, Never>?

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    private var setup: AISetup { .shared }

    var body: some View {
        SettingsPageGate(section: .ai, isLoaded: setup.keysLoaded) {
            providerGroup
            providerDetailsGroup
        } skeleton: {
            SettingsSkeletonGroup(rows: 2)
            SettingsSkeletonGroup(rows: 4)
        }
        .onChange(of: model.settingsToken, initial: true) {
            if model.settingsSection == .ai { setup.reloadKeys() }
        }
        .onChange(of: setup.provider) {
            cancelTest()
            keyDraft = ""
            keyError = nil
        }
        .onDisappear {
            cancelTest()
            keyDraft = ""
        }
        #if DEBUG
        // `-HistqAI test` (stub runs only): clicks Test Connection once the keys are read.
        .task(id: setup.keysLoaded) {
            guard setup.keysLoaded, setup.isReady, AIStub.takeSeam("test") else { return }
            runTest(setup.provider)
        }
        #endif
    }

    // MARK: Provider

    private var providerGroup: some View {
        SettingsGroup("Provider", description: "Histq sends a diff, a commit or one conflict to the provider only when "
            + "you click Generate Message, Explain, Suggest Resolution or Test Connection. Nothing is saved, staged or "
            + "committed until you apply it.") {
            LabeledContent {
                CapsuleMenuPicker(label: "AI provider",
                                  selection: Binding(get: { setup.provider }, set: { setup.setProvider($0) }),
                                  title: Text(setup.provider.displayName)) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } label: {
                Text("Active provider")
                SettingsHint("The AI buttons in the commit box, the commit details and the conflict editor use it.")
            }
            SettingsDivider()
            LabeledContent {
                if let problem = setup.setupProblem(setup.provider) {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } label: {
                Text("Status")
                SettingsHint("\(setup.provider.displayName) with \(modelName)")
            }
        }
    }

    private var modelName: String {
        let name = setup.model(for: setup.provider)
        return name.isEmpty ? "no model yet" : name
    }

    // MARK: Provider details

    private var providerDetailsGroup: some View {
        let provider = setup.provider
        return SettingsGroup(provider.displayName) {
            if provider == .custom {
                baseURLRow
                SettingsDivider()
            }
            keyRow(provider)
            SettingsDivider()
            modelRow(provider)
            SettingsDivider()
            testRow(provider)
        }
    }

    private var baseURLRow: some View {
        LabeledContent {
            TextField("Base URL", text: Binding(get: { setup.customBaseURL }, set: { setup.setCustomBaseURL($0) }),
                      prompt: Text(verbatim: "https://example.com/v1"))
                .textFieldStyle(.settings)
                .frame(maxWidth: 280)
                .labelsHidden()
        } label: {
            Text("Base URL")
            if let error = setup.customURLError, !setup.customBaseURL.isEmpty {
                Text(error.description)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsHint("An OpenAI-compatible server (chat completions). https, or http for this Mac only.")
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ provider: AIProvider) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if keyBusy {
                    ProgressView().controlSize(.small)
                }
                if setup.keyStored[provider] == true {
                    Text(verbatim: "••• saved")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("API key saved")
                    Button("Remove") { removeKey(provider) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(keyBusy)
                } else {
                    SecureField("API key", text: $keyDraft, prompt: Text(verbatim: "sk-…"))
                        .textFieldStyle(.settings)
                        .frame(maxWidth: 240)
                        .labelsHidden()
                        .onSubmit { saveKey(provider) }
                    Button("Save") { saveKey(provider) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(keyBusy || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } label: {
            Text("API key")
            if let keyError {
                Text(keyError)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsHint(provider.requiresAPIKey ? "Kept in your login Keychain; only sent to \(hostName(provider))."
                    : "Optional (many local servers take none). Kept in your login Keychain.")
            }
        }
    }

    private func hostName(_ provider: AIProvider) -> String {
        URL(string: provider.defaultBaseURL)?.host() ?? provider.displayName
    }

    private func modelRow(_ provider: AIProvider) -> some View {
        LabeledContent {
            TextField("Model", text: Binding(get: { setup.typedModel(for: provider) },
                                             set: { setup.setTypedModel($0, for: provider) }),
                      prompt: Text(verbatim: provider.defaultModel.isEmpty ? "model id" : provider.defaultModel))
                .textFieldStyle(.settings)
                .frame(maxWidth: 240)
                .labelsHidden()
        } label: {
            Text("Model")
            SettingsHint(provider.defaultModel.isEmpty ? "The model id your server serves."
                : "Empty uses \(provider.defaultModel). Any model id of the provider works.")
        }
    }

    private func testRow(_ provider: AIProvider) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if test == .running {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: cancelTest)
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } else {
                    Button("Test Connection") { runTest(provider) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(setup.setupProblem(provider) != nil)
                        .help(setup.setupProblem(provider) ?? "Sends a one-line prompt to \(provider.displayName)")
                }
            }
        } label: {
            Text("Test connection")
            switch test {
            case .idle, .running:
                SettingsHint("Sends a one-line prompt and waits for the first words of the answer.")
            case .succeeded(let text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.settingsCaption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let text):
                Text(text)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Actions

    private func saveKey(_ provider: AIProvider) {
        let draft = keyDraft
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !keyBusy else { return }
        // The key stays in the page's state no longer than the save, a failed one included.
        keyDraft = ""
        keyBusy = true
        keyError = nil
        Task {
            do {
                try await setup.saveKey(draft, for: provider)
            } catch {
                keyError = "The key was not saved: \(String(describing: error))"
            }
            keyBusy = false
        }
    }

    private func removeKey(_ provider: AIProvider) {
        cancelTest()
        keyBusy = true
        keyError = nil
        Task {
            do {
                try await setup.removeKey(for: provider)
            } catch {
                keyError = "The key could not be removed: \(String(describing: error))"
            }
            keyBusy = false
        }
    }

    /// A tiny prompt; success needs at least one text piece, since a 200 answer that is not a stream ends with no text
    /// and no error.
    private func runTest(_ provider: AIProvider) {
        testTask?.cancel()
        test = .running
        let modelName = setup.model(for: provider)
        testTask = Task {
            do {
                let client = try await setup.makeClient(for: provider)
                let request = AIChatRequest(
                    model: modelName, system: "You are a connection check. Answer briefly.",
                    messages: [AIChatMessage(role: .user, text: "Reply with the single word OK.")], maxTokens: 16)
                var pieces = 0
                for try await piece in client.stream(request) where !piece.isEmpty {
                    pieces += 1
                    // The first words prove the connection; the rest is not needed.
                    if pieces >= 4 { break }
                }
                try Task.checkCancellation()
                guard pieces > 0 else {
                    test = .failed("\(provider.displayName) answered without any text. Check the model and the base URL.")
                    return
                }
                test = .succeeded("\(provider.displayName) answered with \(modelName).")
                #if DEBUG
                AIStub.log("test-connection ok \(provider.rawValue) pieces \(pieces)")
                #endif
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                test = .failed(String(describing: error))
                #if DEBUG
                AIStub.log("test-connection failed \(provider.rawValue): \(String(describing: error))")
                #endif
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        if test == .running { test = .idle }
    }
}
