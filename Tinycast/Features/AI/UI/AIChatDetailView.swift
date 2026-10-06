import AppKit
import SwiftUI

/// The window's right-hand side: the open conversation, and its composer beneath it.
struct AIChatDetailView: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    @Environment(ChatFindState.self) private var find
    @State private var isDropTargeted = false
    @State private var showsContext = false

    private var chat: AIChatState { coordinator.chats.window }

    /// The last reply's options, once it has finished; typing or sending moves past them.
    private var suggestions: [String] {
        guard !chat.isStreaming, let last = chat.session.messages.last, last.role == .assistant,
            last.state == .complete
        else { return [] }
        return ChatChoices.split(last.text).choices
    }

    var body: some View {
        GeometryReader { geometry in
            pane(composerHeight: ChatComposerTextView.maximumHeight(in: geometry.size.height))
        }
        .animation(.easeOut(duration: Theme.Duration.tooltip), value: showsContext)
        .dropDestination(for: URL.self) { files, _ in
            coordinator.attach(files: files, to: chat)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted { dropHint }
        }
    }

    private func pane(composerHeight: CGFloat) -> some View {
        // Stacked, not floated: the transcript ends where the composer begins, never beneath it.
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // In the transcript's own frame, so the card can never leave the window.
                .overlay(alignment: .bottom) {
                    if showsContext {
                        HStack {
                            Spacer(minLength: 0)
                            ContextCard(report: coordinator.contextReport(for: chat))
                        }
                        .frame(maxWidth: Theme.Size.aiChatReadingWidth)
                        .padding(.horizontal, Theme.Spacing.xxl)
                        .padding(.bottom, Theme.Spacing.sm)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if !suggestions.isEmpty, chat.draft.isEmpty {
                    ChatSuggestionChips(choices: suggestions) { coordinator.send($0, in: chat) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                AIChatComposer(
                    chat: chat, coordinator: coordinator, settings: coordinator.aiSettings,
                    maximumTextHeight: composerHeight, showsContext: $showsContext,
                    isDropTargeted: $isDropTargeted)
            }
            .frame(maxWidth: Theme.Size.aiChatReadingWidth)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.sm)
            .animation(.snappy, value: suggestions)
            .animation(.snappy, value: chat.draft.isEmpty)
        }
    }

    @ViewBuilder private var content: some View {
        if chat.session.messages.isEmpty {
            // Read in the body, so a CLI signing in or a provider switched on is seen at once.
            let unavailability = coordinator.availability(for: chat)
            AIEmptyState(
                message: chat.notice ?? unavailability,
                canConfigure: chat.notice != nil || unavailability != nil,
                onConfigure: coordinator.showSettings)
        } else {
            let occurrences = find.occurrences(in: chat.session.messages)
            ChatTranscriptView(
                messages: chat.displayMessages, status: chat.liveStatus, usage: chat.usage,
                surface: .window,
                onRegenerate: chat.isStreaming ? nil : { coordinator.regenerate(in: chat) },
                find: find.isSearching
                    ? ChatFindHighlight(
                        query: find.needle, matches: Set(occurrences.map(\.messageID)),
                        current: find.currentOccurrence(in: occurrences))
                    : nil
            )
            // A switched chat is a new scroll: its own tail-following, opening at its latest line.
            .id(chat.session.id)
            .overlay(alignment: .topTrailing) {
                if find.isSearching {
                    FindCounter(
                        position: occurrences.isEmpty
                            ? 0 : min(find.current, occurrences.count - 1) + 1,
                        count: occurrences.count,
                        step: { find.step($0, in: chat.session.messages) }
                    )
                    .padding(Theme.Spacing.md)
                }
            }
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(
                Theme.Colors.dropTarget,
                style: StrokeStyle(lineWidth: Theme.Size.dropHintStroke, dash: [Theme.Size.dropHintDash])
            )
            .padding(Theme.Spacing.md)
            .allowsHitTesting(false)
    }
}

/// Staged files, the text, then the chat's options and Send, on one pane of Liquid Glass.
private struct AIChatComposer: View {
    let chat: AIChatState
    let coordinator: AIChatCoordinator
    let settings: AISettingsStore
    let maximumTextHeight: CGFloat
    @Binding var showsContext: Bool
    @Binding var isDropTargeted: Bool
    @State private var editor = ComposerTextViewHandle()

    private var canSend: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chat.pendingAttachments.isEmpty
    }

    var body: some View {
        @Bindable var chat = chat
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if !chat.session.messages.isEmpty, let notice = chat.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.sm)
            }
            chips
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text("Ask anything…")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ChatComposerTextView(
                    text: $chat.draft, focusKey: chat.session.id,
                    maximumTextHeight: maximumTextHeight, handle: editor,
                    isFileDragTargeted: $isDropTargeted,
                    onDropFiles: { coordinator.attach(files: $0, to: chat) },
                    onInvalidate: { coordinator.dictation.cancel(in: $0) }, onSubmit: submit)
            }
            // The text's edge is the + glyph's, which sits centred in its own hover square.
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.top, Theme.Spacing.xs)
            controls
        }
        .padding(Theme.Spacing.md)
        .background {
            Color.clear.glassEffect(
                .regular, in: RoundedRectangle(cornerRadius: Theme.Radius.dialog, style: .continuous))
        }
        .animation(.snappy, value: settings.webSearchEnabled)
    }

    @ViewBuilder private var chips: some View {
        let addressed = coordinator.addressedServer(in: chat.draft)
        if !chat.pendingAttachments.isEmpty || addressed != nil {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.sm) {
                    if let addressed {
                        ComposerChip(symbol: "wrench.and.screwdriver", label: "@\(addressed.slug)")
                    }
                    ForEach(chat.pendingAttachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            coordinator.removeAttachment(attachment.id, in: chat)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Search gives up its word before the model name starts to truncate.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(compactSearch: false)
            controlRow(compactSearch: true)
        }
    }

    private func controlRow(compactSearch: Bool) -> some View {
        let searches = coordinator.capabilities(for: chat).webSearch
        return HStack(spacing: Theme.Spacing.xxs) {
            AIAddMenu(chat: chat, coordinator: coordinator, settings: settings, offersSearch: searches)
            if searches, settings.webSearchEnabled {
                WebSearchPill(settings: settings, isCompact: compactSearch)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Spacer(minLength: Theme.Spacing.md)
            AIModelPicker(chat: chat, selected: coordinator.model(for: chat), coordinator: coordinator)
                .layoutPriority(-1)
            AIReasoningPicker(chat: chat, coordinator: coordinator)
            ContextGauge(
                report: coordinator.contextReport(for: chat, detailed: false), hovered: $showsContext)
            if coordinator.dictation.isEnabled {
                DictationButton(
                    dictation: coordinator.dictation, editor: editor,
                    onNeedsModel: coordinator.showDictationSettings)
            }
            sendButton.padding(.leading, Theme.Spacing.sm)
        }
    }

    /// A solid disc, so Send is the one strong mark on a row of quiet controls.
    private var sendButton: some View {
        let enabled = chat.isStreaming || canSend
        return Button(action: submit) {
            Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                .font(chat.isStreaming ? Theme.Typography.composerStop : Theme.Typography.composerSend)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(enabled ? Theme.Colors.composerSendInk : Theme.Colors.textTertiary)
                .frame(width: Theme.Size.aiChatComposerControl, height: Theme.Size.aiChatComposerControl)
                .background(
                    Circle().fill(enabled ? Theme.Colors.composerSend : Theme.Colors.controlSurface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: Theme.Duration.hover), value: enabled)
        .help(chat.isStreaming ? "Stop Response" : "Send  ↵")
        .accessibilityLabel(chat.isStreaming ? "Stop Response" : "Send")
    }

    /// Return and the button are one action: Send, or Stop while a reply streams.
    private func submit() {
        if chat.isStreaming {
            coordinator.stopResponse(in: chat)
        } else if coordinator.send(chat.draft, in: chat) {
            chat.draft = ""
        }
    }
}

/// A composer control's face: one glyph slot, the callout title, then the menu's chevron.
private struct ComposerControlLabel<Icon: View>: View {
    var title: String?
    var showsChevron = true
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if Icon.self != EmptyView.self {
                icon.frame(width: Theme.Size.aiChatComposerGlyph, height: Theme.Size.aiChatComposerGlyph)
            }
            if let title {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(Theme.Typography.disclosure)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, title == nil && !showsChevron ? 0 : Theme.Spacing.md)
        .frame(minWidth: Theme.Size.aiChatComposerControl)
        .frame(height: Theme.Size.aiChatComposerControl)
        .contentShape(Rectangle())
        // One element: VoiceOver would otherwise read the mark and the chevron as menus of their own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "")
    }
}

extension ComposerControlLabel where Icon == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

private struct ComposerSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name).font(Theme.Typography.composerSymbol)
    }
}

/// Bare at rest and filled under the pointer, so the row reads as one line until it is used.
private struct ComposerControlChrome: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous)
        content
            .background(shape.fill(hovered ? Theme.Colors.controlSurface : Color.clear))
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
    }
}

extension View {
    fileprivate func composerControl() -> some View {
        modifier(ComposerControlChrome())
    }

    /// A stock menu with Tinycast's own face, so its hover and sizes match the rest of the row.
    fileprivate func composerMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .composerControl()
    }
}

/// Files, web search and tools are set now and then, so one + holds them all.
private struct AIAddMenu: View {
    let chat: AIChatState
    let coordinator: AIChatCoordinator
    let settings: AISettingsStore
    let offersSearch: Bool

    var body: some View {
        @Bindable var settings = settings
        Menu {
            Button("Attach Files…", systemImage: "paperclip") { coordinator.chooseFiles(for: chat) }
                .help(attachHelp)
            Divider()
            if offersSearch {
                Toggle("Web Search", systemImage: "globe", isOn: $settings.webSearchEnabled)
            }
            AIToolsMenu(chat: chat, coordinator: coordinator)
        } label: {
            ComposerControlLabel(showsChevron: false) { ComposerSymbol(name: "plus") }
        }
        .composerMenu()
        .help("Attach files, search the web, choose tools")
        .accessibilityLabel("Add")
    }

    /// One entry for every kind; what this chat's model can read is what the help says.
    private var attachHelp: String {
        let can = coordinator.capabilities(for: chat)
        switch (can.images, can.documents) {
        case (true, true): return "Attach images, PDFs or text files"
        case (true, false): return "Attach images or text files"
        case (false, true): return "Attach PDFs or text files"
        case (false, false): return "Attach text files"
        }
    }
}

/// Only while Dictation is on: a click starts it into this field, another click inserts the text.
private struct DictationButton: View {
    let dictation: DictationCoordinator
    let editor: ComposerTextViewHandle
    let onNeedsModel: () -> Void

    var body: some View {
        let field = dictation.field
        let session = field?.editor == editor.textView.map(ObjectIdentifier.init) ? field : nil
        Button {
            guard dictation.hasModel else { return onNeedsModel() }
            if let textView = editor.textView { dictation.toggle(into: textView) }
        } label: {
            Group {
                if session?.isTranscribing == true {
                    ProgressView().controlSize(.small)
                } else if session != nil {
                    ComposerSymbol(name: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(Color.accentColor)
                } else {
                    ComposerSymbol(name: "mic")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .frame(width: Theme.Size.aiChatComposerControl, height: Theme.Size.aiChatComposerControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .composerControl()
        .disabled(session?.isTranscribing == true)
        .help(help(session))
        .accessibilityLabel(session == nil ? "Dictate" : "Stop Dictating")
    }

    private func help(_ session: DictationField?) -> String {
        guard dictation.hasModel else { return "Download a dictation model in Settings" }
        guard let session else { return "Dictate" }
        return session.isTranscribing ? "Transcribing…" : "Stop and insert the text  ↵"
    }
}

/// Web search is on beside the +; a click turns it off, the + menu turns it back on.
private struct WebSearchPill: View {
    let settings: AISettingsStore
    let isCompact: Bool

    var body: some View {
        Button {
            settings.webSearchEnabled = false
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                ComposerSymbol(name: "globe")
                    .frame(width: Theme.Size.aiChatComposerGlyph, height: Theme.Size.aiChatComposerGlyph)
                if !isCompact { Text("Search").font(.callout) }
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, isCompact ? 0 : Theme.Spacing.md)
            .frame(minWidth: Theme.Size.aiChatComposerControl)
            .frame(height: Theme.Size.aiChatComposerControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .composerControl()
        .help("Web search is on; click to turn it off")
        .accessibilityLabel("Web search is on")
    }
}

/// Every configured model, grouped by where it runs; the pick belongs to this chat.
private struct AIModelPicker: View {
    let chat: AIChatState
    /// Handed in, never read from `chat`: a reply writes the session on every streaming flush.
    let selected: AIModelSelection?
    let coordinator: AIChatCoordinator

    var body: some View {
        let groups = coordinator.modelGroups
        Menu {
            if coordinator.isModelCatalogLoading {
                Text("Loading models…")
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Toggle(
                            isOn: Binding(
                                get: { selected.map(option.matches) ?? false },
                                set: { if $0 { coordinator.selectModel(option, in: chat) } })
                        ) {
                            Label {
                                Text(option.title)
                            } icon: {
                                MenuIconImage(icon: option.menuIcon)
                            }
                        }
                    }
                }
            }
            if groups.isEmpty, !coordinator.isModelCatalogLoading {
                Button("Configure AI…", action: coordinator.showSettings)
            }
        } label: {
            ComposerControlLabel(
                title: coordinator.modelTitle(of: selected, among: groups.flatMap(\.options))
            ) {
                MenuIconImage(icon: coordinator.modelIcon(of: selected), edge: Theme.Size.menuBrandIcon)
                    .font(Theme.Typography.composerSymbol)
            }
        }
        .composerMenu()
        .help("Switch this chat's model")
    }
}

private struct AIReasoningPicker: View {
    let chat: AIChatState
    let coordinator: AIChatCoordinator

    /// Shown even when the model has no efforts, so the row never changes shape under the reader.
    var body: some View {
        let efforts = coordinator.reasoningEfforts(for: chat)
        let selected = coordinator.model(for: chat)?.effort
        Menu {
            ForEach(efforts, id: \.id) { effort in
                Toggle(
                    effort.title,
                    isOn: Binding(
                        get: { selected == effort.id },
                        set: { if $0 { coordinator.selectReasoningEffort(effort, in: chat) } }))
            }
        } label: {
            // A word, not a glyph: beside the model's name it already reads as that model's setting.
            ComposerControlLabel(
                title: efforts.isEmpty ? "Reasoning" : coordinator.selectedReasoningTitle(for: chat))
        }
        .composerMenu()
        .disabled(efforts.isEmpty)
        .help(efforts.isEmpty ? "This model has no reasoning setting" : "Change reasoning effort")
    }
}

/// This chat's MCP servers: all of them, some, or none; the model must be one that calls tools.
private struct AIToolsMenu: View {
    let chat: AIChatState
    let coordinator: AIChatCoordinator

    var body: some View {
        let servers = coordinator.mcpServers
        let scope = chat.toolScope
        let takesTools = coordinator.capabilities(for: chat).tools
        let bash = coordinator.isBashToolArmed
        let files = coordinator.isFileToolArmed
        let pages = coordinator.isReadPageToolArmed
        let offered = servers.count + (bash ? 1 : 0) + (files ? 1 : 0) + (pages ? 1 : 0)
        let active =
            servers.filter { scope.allows($0.slug) }.count
            + (bash && scope.allows("bash") ? 1 : 0) + (files && scope.allows("files") ? 1 : 0)
            + (pages && scope.allows(ReadPageTool.slug) ? 1 : 0)
        Menu {
            if offered == 0 {
                Text("No MCP servers are connected")
            } else {
                Toggle(
                    "Use Tools",
                    isOn: Binding(
                        get: { scope.isEnabled },
                        set: { coordinator.setToolsEnabled($0, in: chat) }))
                if bash {
                    Toggle(
                        "Bash",
                        isOn: Binding(
                            get: { scope.allows("bash") },
                            set: { _ in coordinator.toggleToolServer("bash", in: chat) }))
                        .disabled(!scope.isEnabled)
                }
                if files {
                    Toggle(
                        "Files",
                        isOn: Binding(
                            get: { scope.allows("files") },
                            set: { _ in coordinator.toggleToolServer("files", in: chat) }))
                        .disabled(!scope.isEnabled)
                }
                if pages {
                    Toggle(
                        "Read pages",
                        isOn: Binding(
                            get: { scope.allows(ReadPageTool.slug) },
                            set: { _ in coordinator.toggleToolServer(ReadPageTool.slug, in: chat) }))
                        .disabled(!scope.isEnabled)
                }
            if !servers.isEmpty {
                Section("Servers") {
                    ForEach(servers) { server in
                        Toggle(
                            server.name.isEmpty ? server.slug : server.name,
                            isOn: Binding(
                                get: { scope.allows(server.slug) },
                                set: { _ in coordinator.toggleToolServer(server.slug, in: chat) })
                        )
                        .disabled(!scope.isEnabled)
                    }
                }
            }
            }
            Divider()
            Button("MCP Settings…", action: coordinator.showMCPSettings)
        } label: {
            Label(
                !takesTools
                    ? "Tools · Not with this model"
                    : offered == 0 || !scope.isEnabled ? "Tools" : "\(active) of \(offered)",
                systemImage: "wrench.and.screwdriver"
            )
            .labelStyle(.titleAndIcon)
        }
        .disabled(!takesTools)
    }
}

/// Where find is in the open chat, with the same steps ⌘G and ⇧⌘G take.
private struct FindCounter: View {
    let position: Int
    let count: Int
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(count == 0 ? "No matches" : "\(position) of \(count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous Match  ⇧⌘G")
            .disabled(count == 0)
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next Match  ⌘G")
            .disabled(count == 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .glassEffect(.regular, in: Capsule())
    }
}

///  A pair of arrow-beside-ring gauges: the last turn's input with its arrow, the reply with its own.
private struct ContextGauge: View {
    let report: ChatContextReport
    @Binding var hovered: Bool
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            gauge("arrow.up", share: report.inputShare, label: report.inputSummary)
            gauge("arrow.down", share: report.outputShare, label: report.outputSummary)
        }
        .padding(.horizontal, metrics.spacing.xs)
        .frame(width: Theme.Size.aiChatComposerControl, height: Theme.Size.aiChatComposerControl)
        .composerControl()
        .onHover { hovered = $0 }
    }

    /// One direction: its arrow beside the ring, the pair reading as one gauge.
    private func gauge(_ symbol: String, share: Double, label: String) -> some View {
        HStack(spacing: metrics.spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: metrics.scaled(10), weight: .semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
            ContextRing(fill: min(max(share, 0), 1), tint: report.tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

struct ContextRing: View {
    let fill: Double
    let tint: Color
    @Environment(\.metrics) private var metrics

    var body: some View {
        ZStack {
            Circle().stroke(
                Theme.Colors.border, lineWidth: metrics.scaled(Theme.Size.contextRingStroke))
            Circle()
                .trim(from: 0, to: fill)
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: metrics.scaled(Theme.Size.contextRingStroke), lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(
            width: metrics.scaled(Theme.Size.chatContextGauge),
            height: metrics.scaled(Theme.Size.chatContextGauge))
    }
}

/// Tinycast's own card, never a popover: the tokens the chat holds, then what the next turn sends.
struct ContextCard: View {
    let report: ChatContextReport
    // The output meter's scale: a round figure to feel the session's spend against, not a cap.
    private static let outputMeterScale = 16_000
    @Environment(\.metrics) private var metrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.menuPanel, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            HStack {
                Text("Context").font(metrics.typography.panelTitle)
                Spacer(minLength: metrics.spacing.xxl)
                Text(report.fill.formatted(.percent.precision(.fractionLength(0))))
                    .font(metrics.typography.panelTitle)
                    .monospacedDigit()
                    .foregroundStyle(report.tint)
            }
            ProgressView(value: min(report.fill, 1))
                .tint(report.tint)
            if report.historyBytes > report.budget {
                Text("The oldest messages no longer fit and are left out.")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.destructive)
            }
            Grid(
                alignment: .leading, horizontalSpacing: metrics.spacing.xl,
                verticalSpacing: metrics.spacing.xs
            ) {
                section("Session total")
                row("Input", sessionTokens(report.sessionInput, of: report.modelWindow))
                row("Output", sessionTokens(report.sessionOutput, of: Self.outputMeterScale))
                section("Last reply")
                if let usage = report.usage, reportsTokens(usage) {
                    if let context = usage.contextTokens {
                        row("In context", tokens(context, of: usage.contextWindow ?? report.modelWindow))
                    }
                    if usage.inputTokens != nil {
                        row("Input", input(usage))
                    }
                    if usage.outputTokens != nil {
                        row("Output", output(usage))
                    }
                    if let cost = usage.costUSD {
                        row(
                            "Cost",
                            cost.formatted(
                                .currency(code: "USD").precision(.significantDigits(2))))
                    }
                } else {
                    row("Usage", "Not reported yet")
                }
                section("Next message")
                row("Model", report.modelTitle)
                row("History", "\(bytes(report.historyBytes)) of \(bytes(report.budget))")
                row("Messages", "\(report.sentMessages) of \(report.totalMessages)")
                if report.stagedFiles > 0 {
                    row("Attached", "\(report.stagedFiles) · \(bytes(report.stagedBytes))")
                }
                row("System prompt", report.systemPrompt ? "On" : "Off")
                row("Web search", report.webSearch ? "On" : "Off")
                row(
                    "MCP servers",
                    report.toolServers == 0 ? "None" : "\(report.toolServers) in reach")
            }
            .font(metrics.typography.rowTrailing)
        }
        .padding(metrics.spacing.xl)
        .frame(width: metrics.scaled(Theme.Size.chatContextCard), alignment: .leading)
        .glassEffect(.regular, in: shape)
        // Solid under the glass: the card rises over the transcript, whose text must not show through.
        .background { shape.fill(Theme.Colors.windowSurface) }
        .shadow(color: Theme.Colors.tooltipShadow, radius: metrics.spacing.xl, y: metrics.spacing.xs)
    }

    private func section(_ title: String) -> some View {
        GridRow {
            Text(title.uppercased())
                .font(metrics.typography.disclosure)
                .foregroundStyle(.tertiary)
                .gridCellColumns(2)
                .padding(.top, metrics.spacing.xs)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }

    private func bytes(_ count: Int) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// Only the facts a reply reported become rows; a route that names no prompt says so, not 0.
    private func reportsTokens(_ usage: AIUsage) -> Bool {
        usage.inputTokens != nil || usage.outputTokens != nil || usage.costUSD != nil
    }

    private func tokens(_ count: Int, of window: Int?) -> String {
        guard let window else { return count.formatted() }
        return "\(count.formatted()) of \(window.formatted(.number.notation(.compactName)))"
    }

    /// The meter rows: the session's spend spelled compactly beside a limit where one is known.
    private func sessionTokens(_ count: Int?, of limit: Int? = nil) -> String {
        guard let count else { return "Not reported yet" }
        guard let limit else { return compactTokens(count) }
        return "\(compactTokens(count)) / \(compactTokens(limit))"
    }

    /// 25, 271k, 900k, 1.2m — the compact spell the session's meter reads.
    private func compactTokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return count.formatted()
        case ..<1_000_000: return "\(count / 1_000)k"
        default:
            return (Double(count) / 1_000_000)
                .formatted(.number.precision(.fractionLength(0...1))) + "m"
        }
    }

    private func input(_ usage: AIUsage) -> String {
        let prompt = (usage.inputTokens ?? 0) + (usage.cachedInputTokens ?? 0)
        guard let cached = usage.cachedInputTokens, cached > 0 else { return prompt.formatted() }
        return "\(prompt.formatted()) · \(cached.formatted()) cached"
    }

    private func output(_ usage: AIUsage) -> String {
        let output = usage.outputTokens ?? 0
        guard let thinking = usage.reasoningTokens, thinking > 0 else { return output.formatted() }
        return "\(output.formatted()) · \(thinking.formatted()) thinking"
    }
}

extension ChatContextReport {
    fileprivate var tint: Color {
        if fill >= 1 { return Theme.Colors.destructive }
        return fill >= 0.8 ? Theme.Colors.warning : Theme.Colors.textSecondary
    }

    /// The two rings' fills: the model window's share where one is known, else the turn's split.
    fileprivate var inputShare: Double { share(of: promptCount, against: replyCount) }
    fileprivate var outputShare: Double { share(of: replyCount, against: promptCount) }

    /// The prompt — sent and cached alike — and the reply the route gave back.
    fileprivate var promptCount: Int? {
        guard let usage, usage.inputTokens != nil || usage.cachedInputTokens != nil else {
            return nil
        }
        return (usage.inputTokens ?? 0) + (usage.cachedInputTokens ?? 0)
    }
    fileprivate var replyCount: Int? { usage?.outputTokens }

    /// What VoiceOver reads at each ring; the card carries the exact rows on hover.
    fileprivate var inputSummary: String { summary("Input", count: promptCount) }
    fileprivate var outputSummary: String { summary("Output", count: replyCount) }

    private func share(of count: Int?, against other: Int?) -> Double {
        guard let count, count > 0 else { return 0 }
        if let window = reportedWindow, window > 0 {
            return Double(count) / Double(window)
        }
        return Double(count) / Double(count + (other ?? 0))
    }

    private func summary(_ title: String, count: Int?) -> String {
        guard let count else { return "\(title) not reported yet" }
        if let window = reportedWindow, window > 0 {
            return "\(title) \(count.formatted()) of \(window.formatted()) tokens"
        }
        return "\(title) \(count.formatted()) tokens"
    }
}

/// A menu draws an image at its own size, so a brand mark is redrawn at the symbols' size.
private struct MenuIconImage: View {
    let icon: PopoverMenuIcon
    var edge: CGFloat = 16

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
        case .asset(let name):
            if let image = Self.sized(name, edge: edge) {
                Image(nsImage: image)
            } else {
                Image(systemName: "sparkles")
            }
        case .file, .thumbnail, .blank:
            Image(systemName: "sparkles")
        }
    }

    private static func sized(_ name: String, edge: CGFloat) -> NSImage? {
        guard let source = NSImage(named: name) else { return nil }
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
