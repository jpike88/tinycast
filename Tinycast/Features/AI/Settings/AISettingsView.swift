import SwiftUI

struct AISettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AISettingsStore.self) private var settings
    @Environment(AppSettings.self) private var appSettings
    @Environment(ChatGPTSubscriptionManager.self) private var subscription
    @Environment(InstalledAIManager.self) private var installedAI

    @State private var providersPresented = false

    var body: some View {
        @Bindable var appSettings = appSettings
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: $appSettings.aiEnabled) {
                    SettingsFeatureToggleLabel(
                        anchor: .aiAI, title: "Enable AI",
                        subtitle: "Nothing is loaded or sent while it is off.")
                }
                SettingsRow(
                    title: "Providers", subtitle: providerSummary, anchor: .aiProviders
                ) {
                    Button("Manage…") { providersPresented = true }
                }
            } header: {
                SettingsSectionHeader(.aiAI)
            }

            FeatureCommandsSection(owner: .ai, anchor: .aiCommands)
                .settingsEnabled(appSettings.aiEnabled)

            Group {
                defaultModelSection
                chatSection
                conversationsSection
                systemPromptSection
                MCPSettingsSection()
            }
            .settingsEnabled(appSettings.aiEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.ai)
        .settingsEditorPanel(isPresented: $providersPresented) {
            AIProvidersPanel(onDone: { providersPresented = false })
        }
        .onAppear {
            core.applyInstalledAILifecycle()
        }
        // Switched on with the pane already open, provider status would otherwise stay empty.
        .onChange(of: appSettings.aiEnabled) { core.applyInstalledAILifecycle() }
        .onChange(of: settings.enabledInstalledProviders) {
            core.applyInstalledAILifecycle()
            syncSelection()
        }
        .onChange(of: subscription.models) { syncSelection() }
        .onChange(of: subscription.phase) { syncSelection() }
        .onChange(of: installedAI.statuses) { syncSelection() }
    }

    private var defaultModelSection: some View {
        Section {
            // A Mac with nothing configured is the one that needs telling its free route is off.
            if let reason = appleIntelligenceReason {
                Label(reason, systemImage: "apple.intelligence")
                    .foregroundStyle(.secondary)
            }
            AIModelSelectionRows(
                selection: settings.quickAIDefaultModel,
                select: { $0.map { settings.select($0, surface: .quickAI) } },
                modelLabel: {
                    SettingsRowTitle(.aiDefault, "Quick AI model")
                },
                effortLabel: {
                    SettingsRowTitle(.aiDefault, "Quick AI reasoning effort")
                }
            )
            AIModelSelectionRows(
                selection: settings.defaultModel,
                select: { $0.map { settings.select($0, surface: .chat) } },
                modelLabel: {
                    SettingsRowTitle(.aiDefault, "AI Chat model")
                },
                effortLabel: {
                    SettingsRowTitle(.aiDefault, "AI Chat reasoning effort")
                }
            )
        } header: {
            SettingsSectionHeader(.aiDefault)
        } footer: {
            Text(defaultModelFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var defaultModelFooter: String {
        let chosen = [settings.quickAIDefaultModel, settings.defaultModel]
        if chosen.allSatisfy({ $0?.isOnDevice == true && $0 != nil }) {
            return "Apple Intelligence runs on this Mac. Nothing leaves it."
        }
        return chosen.contains { $0 == nil }
            ? "Turn on Apple Intelligence, or add a provider above."
            : "Only the selected provider is contacted."
    }

    /// Why the on-device route is missing from the picker, or `nil` when it is there.
    private var appleIntelligenceReason: String? {
        settings.isAppleIntelligenceAvailable() ? nil : AppleIntelligenceProvider.status().message
    }

    private var providerSummary: String {
        var providers: [String] = []
        if subscription.isConnected { providers.append("Codex") }
        for kind in InstalledAIKind.managedCLIKinds
        where installedAI.status(for: kind).isReady {
            providers.append(kind.title)
        }
        if !settings.connections.isEmpty {
            let count = settings.connections.count
            providers.append(count == 1 ? "1 API connection" : "\(count) API connections")
        }
        return providers.isEmpty ? "No external providers ready" : providers.joined(separator: ", ")
    }

    private func syncSelection() {
        settings.reconcile(subscription: subscription, installedAI: installedAI)
    }

    private var chatSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.webSearchEnabled) {
                SettingsRowTitle(.aiChat, "Web search")
                Text(
                    "Codex and OpenRouter natively; every other model that calls tools searches "
                        + "Brave's web index. Prompts go to a search engine.")
            }
            if settings.webSearchEnabled {
                WebSearchSettingsRow(settings: settings, core: core)
            }
            Picker(selection: $settings.toolRounds) {
                ForEach(AIToolRounds.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsRowTitle(.aiChat, "Tool call rounds")
                Text(
                    "A reply stops after this many; Unlimited runs until Stop. "
                        + "API connections, Codex and Claude.")
            }
            Toggle(
                isOn: Binding(
                    get: { settings.bashToolEnabled },
                    set: { core.aiChatCoordinator.setBashToolEnabled($0) }))
            {
                SettingsRowTitle(.aiChat, "Bash tool")
                Text(
                    "API models may run shell commands on this Mac. Each command asks first, "
                        + "unless trust below says to stay silent.")
            }
            if settings.bashToolEnabled {
                Picker(selection: $settings.bashTrust) {
                    ForEach(MCPTrust.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsRowTitle(.aiChat, "Bash trust")
                    Text("Never Allow keeps the tool out entirely.")
                }
            }
            Toggle(
                isOn: Binding(
                    get: { settings.fileToolEnabled },
                    set: { core.aiChatCoordinator.setFileToolEnabled($0) }))
            {
                SettingsRowTitle(.aiChat, "File tools")
                Text(
                    "API models may read, search, write and open files in this account's home "
                        + "folder. Reads never ask; each write, delete or open asks first, unless "
                        + "trust below says to stay silent.")
            }
            if settings.fileToolEnabled {
                Picker(selection: $settings.fileToolTrust) {
                    ForEach(MCPTrust.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsRowTitle(.aiChat, "File tool trust")
                    Text("Never Allow keeps the tools out entirely.")
                }
            }
            Toggle(
                isOn: Binding(
                    get: { settings.readPageToolEnabled },
                    set: { core.aiChatCoordinator.setReadPageToolEnabled($0) }))
            {
                SettingsRowTitle(.aiChat, "Read-page tool")
                Text(
                    "API models may fetch one web page per call and read it as text — no shell, "
                        + "no curl, never the local network. Pages past the size cap arrive cut.")
            }
        } header: {
            SettingsSectionHeader(.aiChat)
        }
    }

    private var conversationsSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker(selection: $settings.opensTo) {
                ForEach(AIOpensTo.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsRowTitle(.aiConversations, "Quick AI opens to")
            }
            if settings.opensTo == .recent {
                Picker(selection: $settings.newChatAfter) {
                    ForEach(AINewChatAfter.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsRowTitle(.aiConversations, "Start a new conversation after")
                }
            }
            Picker(selection: $settings.retention) {
                ForEach(AIRetention.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsRowTitle(.aiConversations, "Keep conversations")
                Text("Older ones are deleted, except pinned chats.")
            }
        } header: {
            SettingsSectionHeader(.aiConversations)
        } footer: {
            Text("Conversations stay on this Mac, outside settings backups.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemPromptSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.systemPromptEnabled) {
                SettingsRowTitle(.aiSystemPrompt, "Send a system prompt")
                Text("Off also skips Tinycast's own prompt.")
            }
            SystemPromptEditor(text: $settings.systemPrompt)
                .settingsEnabled(settings.systemPromptEnabled)
        } header: {
            SettingsSectionHeader(.aiSystemPrompt)
        } footer: {
            Text("Sent before every message, after Tinycast's own. Both are billed each turn.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

private /// The built-in `web_search` tool's settings: only the Brave Search API key it calls with.
struct WebSearchSettingsRow: View {
    let settings: AISettingsStore
    let core: AppCore

    private let keyStore = KeychainSecretStore.aiAPIKeys
    @State private var key = ""
    @State private var keyStored = false
    @State private var keyError: String?

    private static let guideTitle = "Setting up web search"
    private static let guideSymbol = "globe"
    private static let guide = """
        Searches run on Brave's web index — results with titles, links and snippets.

        1. Sign in at api-dashboard.search.brave.com and activate the free “Web Search” plan. That's all the setup there is.
        2. Create a subscription's API key and paste it above. It's kept in Keychain, on this Mac only.

        The free plan covers a couple of thousand queries a month at about one a second; a search only runs when the model asks for one.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            LabeledContent {
                HStack(spacing: Theme.Spacing.sm) {
                    SecureField(
                        keyStored ? "Stored in Keychain" : "Paste an API key",
                        text: $key)
                        .frame(maxWidth: 320)
                    if keyStored {
                        Button("Remove") { removeKey() }
                    }
                    Button("Save") { saveKey() }
                        .disabled(key.isEmpty)
                }
            } label: {
                Text("API key (If using Brave Search)")
            }
            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(
                    "The key is stored in Keychain, on this Mac only. Tools run against "
                        + "Brave Search when the selected model has no web search of its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Read more…") { showGuide() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .onAppear { keyStored = (try? keyStore.hasSecret(for: AIWebSearch.keyAccount)) == true }
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keyStore.setSecret(trimmed, for: AIWebSearch.keyAccount)
            keyStored = true
            key = ""
            keyError = nil
        } catch {
            keyError = "The key could not be stored in Keychain."
        }
    }

    private func removeKey() {
        try? keyStore.removeSecret(for: AIWebSearch.keyAccount)
        keyStored = false
        keyError = nil
    }

    private func showGuide() {
        Task {
            await core.showNotice(
                title: Self.guideTitle, message: Self.guide, symbol: Self.guideSymbol,
                tone: .neutral)
        }
    }
}

