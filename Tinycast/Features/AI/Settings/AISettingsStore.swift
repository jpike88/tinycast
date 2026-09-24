import Foundation
import Observation

/// Which chat surface a stored default belongs to: Quick AI and AI Chat each name their own.
enum AIDefaultSurface: CaseIterable, Hashable, Sendable {
    case quickAI
    case chat

    var key: AppSettingsKey {
        switch self {
        case .quickAI: return .aiQuickAIDefaultModel
        case .chat: return .aiDefaultModel
        }
    }
}

@MainActor
@Observable
final class AISettingsStore {
    private let defaults: UserDefaults

    private(set) var connections: [AIConnection] {
        didSet { persistConnections() }
    }
    private(set) var defaultModels: [AIDefaultSurface: AIModelSelection] {
        didSet { persistDefaultModels() }
    }
    var defaultModel: AIModelSelection? {
        get { defaultModels[.chat] }
        set { defaultModels[.chat] = newValue }
    }

    var quickAIDefaultModel: AIModelSelection? {
        get { defaultModels[.quickAI] }
        set { defaultModels[.quickAI] = newValue }
    }

    /// Off by default: a prompt reaches a search engine only once the user has said so.
    var webSearchEnabled: Bool {
        didSet { defaults.set(webSearchEnabled, forKey: AppSettingsKey.aiWebSearch.rawValue) }
    }
    /// Appended to `AIInstructions.preamble` on every turn, so it is billed on every turn.
    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: AppSettingsKey.aiSystemPrompt.rawValue) }
    }
    /// On by default: without it a model has no idea what app it is answering for.
    var systemPromptEnabled: Bool {
        didSet {
            defaults.set(systemPromptEnabled, forKey: AppSettingsKey.aiSystemPromptEnabled.rawValue)
        }
    }
    /// Forever by default, so upgrading deletes nothing the reader did not ask to lose.
    var retention: AIRetention {
        didSet { defaults.set(retention.rawValue, forKey: AppSettingsKey.aiRetention.rawValue) }
    }
    var opensTo: AIOpensTo {
        didSet { defaults.set(opensTo.rawValue, forKey: AppSettingsKey.aiOpensTo.rawValue) }
    }
    var newChatAfter: AINewChatAfter {
        didSet {
            defaults.set(newChatAfter.rawValue, forKey: AppSettingsKey.aiNewChatAfter.rawValue)
        }
    }
    var toolRounds: AIToolRounds {
        didSet { defaults.set(toolRounds.rawValue, forKey: AppSettingsKey.aiToolRounds.rawValue) }
    }
    var enabledInstalledProviders: Set<InstalledAIKind> {
        didSet {
            guard
                let data = try? JSONEncoder().encode(
                    enabledInstalledProviders.sorted(by: {
                        $0.rawValue < $1.rawValue
                    }))
            else { return }
            defaults.set(data, forKey: AppSettingsKey.aiInstalledProviders.rawValue)
        }
    }

    /// Asked each time: the model lands mid-session, and a flag read at launch would never notice.
    @ObservationIgnored let isAppleIntelligenceAvailable: @Sendable () -> Bool

    init(
        defaults: UserDefaults = .standard,
        isAppleIntelligenceAvailable: @escaping @Sendable () -> Bool = { false }
    ) {
        self.defaults = defaults
        self.isAppleIntelligenceAvailable = isAppleIntelligenceAvailable
        connections = Self.decodeConnections(
            defaults.data(forKey: AppSettingsKey.aiConnections.rawValue))
        defaultModels = Self.decodeDefaultModels(defaults)
        webSearchEnabled =
            defaults.object(forKey: AppSettingsKey.aiWebSearch.rawValue) as? Bool ?? false
        systemPrompt = defaults.string(forKey: AppSettingsKey.aiSystemPrompt.rawValue) ?? ""
        systemPromptEnabled =
            defaults.object(forKey: AppSettingsKey.aiSystemPromptEnabled.rawValue) as? Bool ?? true
        // Unset reads as 0, which no retention case carries — `forever` is negative on purpose.
        retention =
            AIRetention(rawValue: defaults.integer(forKey: AppSettingsKey.aiRetention.rawValue))
            ?? .forever
        opensTo =
            AIOpensTo(rawValue: defaults.integer(forKey: AppSettingsKey.aiOpensTo.rawValue))
            ?? .recent
        newChatAfter =
            AINewChatAfter(
                rawValue: defaults.integer(forKey: AppSettingsKey.aiNewChatAfter.rawValue))
            ?? .fiveMinutes
        toolRounds =
            AIToolRounds(rawValue: defaults.integer(forKey: AppSettingsKey.aiToolRounds.rawValue))
            ?? .twentyFive
        enabledInstalledProviders = Self.decodeEnabledInstalledProviders(
            defaults.data(forKey: AppSettingsKey.aiInstalledProviders.rawValue))
        for surface in AIDefaultSurface.allCases {
            if case .api(let connection, let model, _) = defaultModels[surface],
                !connections.contains(where: { $0.id == connection && $0.models.contains(model) })
            {
                defaultModels[surface] = firstAvailableSelection()
            }
            if defaultModels[surface] == nil {
                defaultModels[surface] = firstAvailableSelection()
            }
        }
    }

    func connection(id: UUID) -> AIConnection? {
        connections.first { $0.id == id }
    }

    func select(_ selection: AIModelSelection, surface: AIDefaultSurface) {
        if case .api(let connection, let model, _) = selection {
            guard self.connection(id: connection)?.models.contains(model) == true else { return }
        }
        defaultModels[surface] = selection
    }

    func save(_ connection: AIConnection) {
        let connection = normalized(connection)
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        for surface in AIDefaultSurface.allCases {
            if case .api(connection.id, let model, let effort) = defaultModels[surface] {
                if connection.models.contains(model) {
                    defaultModels[surface] = .api(
                        connection: connection.id, model: model,
                        effort: connection.reasoningOptions(for: model)?.resolvedEffort(effort))
                } else {
                    defaultModels[surface] = connection.models.first.map {
                        .api(
                            connection: connection.id, model: $0,
                            effort: connection.reasoningOptions(for: $0)?.resolvedEffort(nil))
                    }
                }
            }
            if defaultModels[surface] == nil, let model = connection.models.first {
                defaultModels[surface] = .api(
                    connection: connection.id, model: model,
                    effort: connection.reasoningOptions(for: model)?.resolvedEffort(nil))
            }
        }
    }

    func removeConnection(id: UUID) {
        connections.removeAll { $0.id == id }
        for surface in AIDefaultSurface.allCases {
            guard case .api(id, _, _) = defaultModels[surface] else { continue }
            defaultModels[surface] = firstAvailableSelection()
        }
    }

    func reconcile(codexModels models: [ChatGPTSubscription.Model], isUnavailable: Bool) {
        for surface in AIDefaultSurface.allCases {
            guard case .codex(let model, let effort) = defaultModels[surface] else { continue }
            if isUnavailable {
                defaultModels[surface] = firstAvailableSelection()
                continue
            }
            guard !models.isEmpty else { continue }
            if let match = models.first(where: { $0.id == model }) {
                let resolved = match.resolvedEffort(effort)
                if resolved != effort { defaultModels[surface] = .codex(model: model, effort: resolved) }
                continue
            }
            guard let replacement = models.first(where: \.isDefault) ?? models.first else { continue }
            defaultModels[surface] = .codex(
                model: replacement.id, effort: replacement.resolvedEffort(nil))
        }
    }

    func reconcile(
        installed kind: InstalledAIKind, models: [InstalledAIModel], isUnavailable: Bool
    ) {
        for surface in AIDefaultSurface.allCases {
            let selectedModel: String
            switch (kind, defaultModels[surface]) {
            case (.claude, .claude(let model, _)), (.grok, .grok(let model, _)),
                (.openCode, .openCode(let model, _)), (.cursor, .cursor(let model, _)):
                selectedModel = model
            default:
                continue
            }
            if isUnavailable {
                defaultModels[surface] = firstAvailableSelection()
                continue
            }
            guard !models.isEmpty else { continue }
            if let match = models.first(where: { $0.id == selectedModel }) {
                let resolved = match.resolvedEffort(defaultModels[surface]?.effort)
                if resolved != defaultModels[surface]?.effort {
                    defaultModels[surface] = defaultModels[surface]?.withEffort(resolved)
                }
                continue
            }
            guard let replacement = models.first else { continue }
            switch kind {
            case .claude:
                defaultModels[surface] = .claude(
                    model: replacement.id, effort: replacement.resolvedEffort(nil))
            case .grok:
                defaultModels[surface] = .grok(
                    model: replacement.id, effort: replacement.resolvedEffort(nil))
            case .openCode:
                defaultModels[surface] = .openCode(
                    model: replacement.id, effort: replacement.resolvedEffort(nil))
            case .cursor:
                defaultModels[surface] = .cursor(
                    model: replacement.id, effort: replacement.resolvedEffort(nil))
            case .codex: break
            }
        }
    }

    /// Nothing chosen yet takes the route that needs no account, leaving a real stored selection.
    func resolveDefaultModels() {
        for surface in AIDefaultSurface.allCases {
            guard defaultModels[surface] == nil, let selection = firstAvailableSelection() else { continue }
            defaultModels[surface] = selection
        }
    }

    func setInstalledProviderEnabled(_ enabled: Bool, for kind: InstalledAIKind) {
        var providers = enabledInstalledProviders
        if enabled {
            providers.insert(kind)
        } else {
            providers.remove(kind)
        }
        enabledInstalledProviders = providers
    }

    func disableInstalledModelSelection(for kind: InstalledAIKind) {
        for surface in AIDefaultSurface.allCases {
            guard let source = defaultModels[surface]?.source else { continue }
            let matches =
                switch (kind, source) {
                case (.codex, .codex), (.claude, .claude), (.grok, .grok), (.openCode, .openCode),
                    (.cursor, .cursor):
                    true
                default: false
                }
            guard matches else { continue }
            defaultModels[surface] = firstAvailableSelection()
        }
    }

    /// The on-device model leads: free, private, always configured, so never a surprising landing.
    private func firstAvailableSelection() -> AIModelSelection? {
        if isAppleIntelligenceAvailable() { return .appleIntelligence }
        for connection in connections {
            if let model = connection.models.first {
                return .api(
                    connection: connection.id, model: model,
                    effort: connection.reasoningOptions(for: model)?.resolvedEffort(nil))
            }
        }
        return nil
    }

    private func persistConnections() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: AppSettingsKey.aiConnections.rawValue)
    }

    private func persistDefaultModels() {
        for surface in AIDefaultSurface.allCases {
            guard let selection = defaultModels[surface],
                let data = try? JSONEncoder().encode(selection)
            else {
                defaults.removeObject(forKey: surface.key.rawValue)
                continue
            }
            defaults.set(data, forKey: surface.key.rawValue)
        }
    }

    private func normalized(_ connection: AIConnection) -> AIConnection {
        var connection = connection
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.baseURL = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        connection.models = connection.models.compactMap {
            let model = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
        connection.visionModels = connection.visionModels.filter(seen.contains)
        connection.reasoningOptions = connection.reasoningOptions?.filter {
            seen.contains($0.key) && !$0.value.efforts.isEmpty
        }
        if connection.reasoningOptions?.isEmpty == true { connection.reasoningOptions = nil }
        return connection
    }

    private static func decodeConnections(_ data: Data?) -> [AIConnection] {
        guard let data,
            let connections = try? JSONDecoder().decode([AIConnection].self, from: data)
        else { return [] }
        return connections
    }

    private static func decodeDefaultModels(
        _ defaults: UserDefaults
    ) -> [AIDefaultSurface: AIModelSelection] {
        var decoded: [AIDefaultSurface: AIModelSelection] = [:]
        for surface in AIDefaultSurface.allCases {
            guard let data = defaults.data(forKey: surface.key.rawValue) else { continue }
            decoded[surface] = try? JSONDecoder().decode(AIModelSelection.self, from: data)
        }
        return decoded
    }

    private static func decodeEnabledInstalledProviders(_ data: Data?) -> Set<InstalledAIKind> {
        guard let data,
            let providers = try? JSONDecoder().decode([InstalledAIKind].self, from: data)
        else { return [] }
        return Set(providers)
    }
}
