import AIBridge
import Foundation
import IPCProtocol
import Observation

/// Where the assistant keeps its files and how it reaches Claude Code.
public struct AssistantServices: Sendable {
    /// `~/Library/Application Support/Lightwell/assistant` (0700): cwd, MCP configs, prompt, logs, threads.
    public var directory: URL
    /// Folder of the IPC socket.
    public var ipcDirectory: URL
    /// The bundled `lightwell-mcp` helper.
    public var helperURL: URL
    public var peerPolicy: PeerPolicy
    /// Claude binary that wins over the Settings override (fake-claude in UI test mode).
    public var claudeOverride: URL?
    /// `assistant-system-prompt.md` template text.
    public var systemPromptTemplate: String
    public var locatorEnvironment: ClaudeLocator.Environment
    /// Idle sessions close their stdin after this long (PLAN 3.4: 10 minutes).
    public var idleTimeout: Duration

    public init(directory: URL, ipcDirectory: URL, helperURL: URL, peerPolicy: PeerPolicy, claudeOverride: URL? = nil, systemPromptTemplate: String, locatorEnvironment: ClaudeLocator.Environment = .live, idleTimeout: Duration = .seconds(600)) {
        self.directory = directory
        self.ipcDirectory = ipcDirectory
        self.helperURL = helperURL
        self.peerPolicy = peerPolicy
        self.claudeOverride = claudeOverride
        self.systemPromptTemplate = systemPromptTemplate
        self.locatorEnvironment = locatorEnvironment
        self.idleTimeout = idleTimeout
    }

    /// Minimal prompt used when the bundled template is missing (never expected in the app).
    public static let fallbackSystemPrompt = """
    You are the disk space assistant inside Lightwell, a macOS app. Answer in English.
    You see the user's disk only through the disk tools. The scan is {{scanAge}} old and covers {{scannedRoot}}.
    Only the user deletes: propose_deletion just adds items to the cleanup queue for review.
    """

    /// The bundled template from the app's resources, or the fallback.
    public static func bundledSystemPrompt(_ bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: SystemPromptRenderer.templateResourceName, withExtension: SystemPromptRenderer.templateResourceExtension),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return fallbackSystemPrompt }
        return text
    }
}

/// Why the last session was refused, ready for the refusal card (PLAN 3.2b).
public struct AssistantRefusal: Sendable, Hashable {
    public var refusal: SessionRefusal
    public var title: String
    public var reason: String
    public var advice: String
}

/// Assistant store. Frozen contract (PLAN 4.3) plus additive state for the panel.
///
/// One long-lived `claude` process per active thread (`ClaudeSession`), tool calls served by the
/// `IPCServer` with the app's `ToolHandler`, threads saved in `threads.json`. Stream events become
/// transcript items: streamed text, tool chips, proposal cards (pushed by the tool handler),
/// notices and errors (PLAN 3.9). Without services (previews) it only records what is sent.
@Observable
@MainActor
public final class AssistantModel {
    public var availability: AssistantAvailability
    public var threads: [ThreadRecord]
    public var active: UUID?
    public var items: [ChatItem]
    public var usage: UsageSummary
    public private(set) var isResponding = false
    public var draft = ""
    /// The located CLI (Settings shows its version).
    public private(set) var installation: ClaudeInstallation?
    /// `system/init.apiKeySource` of the current session ("none" for a CLI login).
    public private(set) var keySource: String?
    /// The CLI supports interrupting a turn (Stop is disabled otherwise).
    public private(set) var canStop = true
    /// The last session was refused because it would bill an API key.
    public private(set) var refusal: AssistantRefusal?
    /// The CLI crashed: Retry respawns it with `--resume` and resends the last message.
    public private(set) var canRetry = false
    /// The step limit stopped the last reply: Continue lets Claude keep going.
    public private(set) var canContinue = false
    /// The per-thread token guard was reached: Continue raises it once more.
    public private(set) var guardReached = false
    /// Recent CLI stderr for the "Details" disclosure (nonce redacted by the session).
    public private(set) var errorDetails: String?

    @ObservationIgnored private var services: AssistantServices?
    @ObservationIgnored private var handler: (any AssistantToolHandler)?
    @ObservationIgnored private var server: IPCServer?
    @ObservationIgnored private var store: ThreadStore?
    @ObservationIgnored private var session: ClaudeSession?
    @ObservationIgnored private var sessionThread: UUID?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var transcripts: [UUID: [ChatItem]] = [:]
    @ObservationIgnored private var guardBase: [UUID: Int] = [:]
    /// Per-thread estimated cost (cents) already allowed past the spending guard.
    @ObservationIgnored private var costGuardBase: [UUID: Int] = [:]
    @ObservationIgnored private var streamingItem: UUID?
    @ObservationIgnored private var retryItem: UUID?
    @ObservationIgnored private var messageHadText = false
    @ObservationIgnored private var toolStarts: [String: Date] = [:]
    @ObservationIgnored private var toolInputs: [String: String] = [:]
    @ObservationIgnored private var sawInit = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var lastUserMessage: String?
    /// Streamed text waiting for the next transcript update (deltas are coalesced to about 20 per second).
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Current settings (set by `AppModel`).
    @ObservationIgnored public var settings: @MainActor () -> AppSettings = { AppSettings() }
    /// Changes settings (consent, enable). Set by `AppModel`.
    @ObservationIgnored public var updateSettings: @MainActor ((inout AppSettings) -> Void) -> Void = { _ in }
    /// Scan age in seconds and scanned root (`~` form) for the system prompt; nil when no scan exists.
    @ObservationIgnored public var scanInfo: @MainActor () -> (ageSeconds: Int, root: String)? = { nil }

    public init(
        availability: AssistantAvailability = .checking,
        threads: [ThreadRecord] = [],
        active: UUID? = nil,
        items: [ChatItem] = [],
        usage: UsageSummary = UsageSummary()
    ) {
        self.availability = availability
        self.threads = threads
        self.active = active
        self.items = items
        self.usage = usage
    }

    /// Connects the store to Claude Code. Call once, then `recheck()`.
    public func configure(services: AssistantServices, handler: any AssistantToolHandler) {
        self.services = services
        self.handler = handler
        let store = ThreadStore(directory: services.directory)
        self.store = store
        threads = store.threads
    }

    public var isLive: Bool { services != nil }

    /// True while a reply streams or a tool call runs (the composer shows Stop).
    public var isBusy: Bool {
        if isResponding { return true }
        guard let last = items.last else { return false }
        switch last.kind {
        case .assistant(_, let isStreaming): return isStreaming
        case .tool(let activity): return activity.state == .running
        default: return false
        }
    }

    /// Tokens used by the active thread (input including cache, plus output).
    public var activeThreadTokens: Int {
        guard let active, let record = threads.first(where: { $0.id == active }) else { return 0 }
        return record.totalTokens
    }

    // MARK: Availability

    /// True once `recheck()` looked for the CLI in this launch (nothing runs before the consent).
    public private(set) var hasLookedForCLI = false

    /// Sets `availability` without running anything (launch): off, waiting for the consent, or
    /// `.checking` until the panel or Settings asks (`checkIfNeeded()`). PLAN 3.11: before the
    /// consent no `claude` process and no login shell is started.
    public func prepare() {
        guard services != nil else { return }
        let settings = settings()
        if !settings.assistantEnabled {
            availability = .disabled
        } else if !settings.assistantConsentAccepted {
            availability = .needsConsent
        } else {
            availability = .checking
        }
    }

    /// Looks for the CLI the first time the assistant is shown after the consent (panel, Settings).
    public func checkIfNeeded() {
        guard services != nil, !hasLookedForCLI else { return }
        let settings = settings()
        guard settings.assistantEnabled, settings.assistantConsentAccepted else { return }
        recheck()
    }

    /// Finds the CLI, checks the login and the consent, and sets `availability`. Before the
    /// consent it only reports `.needsConsent`: no `claude --version`, no `claude auth status`
    /// and no login-shell lookup run until the user has accepted (PLAN 3.11).
    public func recheck() {
        guard let services else { return }
        recheckTask?.cancel()
        recheckTask = nil
        let settings = settings()
        guard settings.assistantEnabled else {
            availability = .disabled
            return
        }
        guard settings.assistantConsentAccepted else {
            availability = .needsConsent
            return
        }
        hasLookedForCLI = true
        availability = .checking
        let override = services.claudeOverride ?? settings.claudePathOverride.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let environment = services.locatorEnvironment
        let directory = services.directory
        recheckTask = Task { [weak self] in
            let found: ClaudeInstallation
            do {
                found = try await ClaudeLocator.locate(override: override, environment: environment)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installation = nil
                self.availability = .notInstalled
                return
            }
            Self.ensurePrivateDirectory(directory)
            let status = await ClaudeAuthStatus.fetch(claude: found.resolvedURL, environment: ClaudeCommandBuilder.childEnvironment(), workingDirectory: directory)
            guard let self, !Task.isCancelled else { return }
            self.installation = found
            if status?.loggedIn == false {
                self.availability = .notSignedIn
            } else if !self.settings().assistantConsentAccepted {
                self.availability = .needsConsent
            } else {
                self.availability = .ready(version: found.version)
            }
        }
    }

    /// Waits for a running `recheck()` (tests).
    public func waitForRecheck() async {
        await recheckTask?.value
    }

    public func acceptConsent() {
        updateSettings { $0.assistantConsentAccepted = true }
        guard services != nil else {
            availability = .ready(version: nil)
            return
        }
        if let installation, availability == .needsConsent {
            availability = .ready(version: installation.version)
        } else {
            recheck()
        }
    }

    /// Turns the assistant back on from the panel.
    public func enable() {
        updateSettings { $0.assistantEnabled = true }
        if services == nil {
            availability = .ready(version: nil)
        } else {
            recheck()
        }
    }

    /// Applies changed settings (assistant switched off, another binary chosen, another model).
    public func settingsChanged(from old: AppSettings, to new: AppSettings) {
        guard services != nil else { return }
        if !new.assistantEnabled {
            endSession()
            availability = .disabled
        } else if !old.assistantEnabled || old.claudePathOverride != new.claudePathOverride {
            endSession()
            recheck()
        } else if old.assistantModel != new.assistantModel || old.blockAPIKeys != new.blockAPIKeys || old.assistantMaxTurns != new.assistantMaxTurns {
            endSession()
        }
    }

    // MARK: Conversation

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard services != nil else {
            items.append(ChatItem(kind: .user(trimmed)))
            draft = ""
            return
        }
        guard case .ready = availability, !isResponding else { return }
        guard !guardReached else {
            append(.notice(L10n.guardReached))
            return
        }
        draft = ""
        deliver(trimmed, showAs: trimmed)
    }

    public func stop() {
        guard isResponding else { return }
        stopRequested = true
        session?.interrupt()
        finishStreaming()
        isResponding = false
    }

    /// Respawns the CLI with `--resume` after a crash and resends the last message.
    public func retry() {
        guard canRetry, let message = lastUserMessage else { return }
        canRetry = false
        errorDetails = nil
        endSession()
        deliver(message, showAs: nil)
    }

    /// After the step limit (`error_max_turns`) or the token guard: let Claude keep going.
    public func continueReply() {
        if guardReached, let active {
            guardBase[active] = activeThreadTokens
            costGuardBase[active] = threads.first(where: { $0.id == active })?.estimatedCostCents ?? 0
            guardReached = false
        }
        guard case .ready = availability, !isResponding else { return }
        canContinue = false
        deliver(L10n.continueMessage, showAs: L10n.continueMessage)
    }

    public func newThread() {
        endSession()
        saveTranscript()
        let now = Date()
        let thread = ThreadRecord(title: "", createdAt: now, updatedAt: now)
        threads.insert(thread, at: 0)
        active = thread.id
        items = []
        usage = UsageSummary()
        resetTurnFlags()
    }

    public func select(_ id: UUID) {
        guard id != active, let record = threads.first(where: { $0.id == id }) else { return }
        endSession()
        saveTranscript()
        active = id
        if let saved = transcripts[id] {
            items = saved
        } else {
            items = record.turns > 0 ? [ChatItem(kind: .notice(L10n.earlierMessagesHidden))] : []
        }
        usage = Self.usage(of: record)
        resetTurnFlags()
    }

    /// Deletes every saved conversation.
    public func clearThreads() {
        endSession()
        if let store {
            for record in store.threads { try? store.remove(record.id) }
        }
        threads.removeAll()
        transcripts.removeAll()
        guardBase.removeAll()
        costGuardBase.removeAll()
        items.removeAll()
        active = nil
        usage = UsageSummary()
        resetTurnFlags()
    }

    /// Shows a `propose_deletion` result as a card (called by the tool handler).
    public func receive(_ batch: ProposalBatch, thread: UUID) {
        let item = ChatItem(kind: .proposal(batch))
        if thread == active {
            finishStreaming()
            items.append(item)
        } else {
            transcripts[thread, default: []].append(item)
        }
    }

    /// App quit: interrupt, close stdin, SIGTERM after 3 s, stop the socket server.
    public func shutdown() {
        session?.shutdown(grace: 3)
        session = nil
        sessionThread = nil
        eventsTask?.cancel()
        idleTask?.cancel()
        server?.stop()
        server = nil
    }

    // MARK: Session plumbing

    private func deliver(_ text: String, showAs shown: String?) {
        guard let services, let installation else { return }
        if active == nil || !threads.contains(where: { $0.id == active }) {
            let now = Date()
            let thread = ThreadRecord(title: "", createdAt: now, updatedAt: now)
            threads.insert(thread, at: 0)
            active = thread.id
        }
        guard let thread = active else { return }
        if let shown { append(.user(shown)) }
        lastUserMessage = text
        refusal = nil
        canRetry = false
        canContinue = false
        stopRequested = false
        do {
            let session = try ensureSession(thread: thread, firstMessage: text, services: services, installation: installation)
            try session.send(text)
            isResponding = true
            messageHadText = false
            touchIdle()
        } catch AssistantSessionError.refused(let reason) {
            showRefusal(reason)
        } catch {
            isResponding = false
            errorDetails = String(describing: error)
            append(.error(L10n.launchFailed))
            canRetry = true
            endSession()
        }
    }

    private func ensureSession(thread: UUID, firstMessage: String, services: AssistantServices, installation: ClaudeInstallation) throws -> ClaudeSession {
        if let session, sessionThread == thread, session.exitStatus == nil, session.refusal == nil { return session }
        endSession()
        let server = try ensureServer(services)
        let settings = settings()
        var resume = false
        if let store {
            if let record = store.thread(thread) {
                resume = record.turns > 0
            } else {
                let record = try store.createThread(id: thread, firstMessage: firstMessage, model: settings.assistantModel ?? ClaudeCommandBuilder.defaultModel)
                if let index = threads.firstIndex(where: { $0.id == thread }) { threads[index] = record } else { threads.insert(record, at: 0) }
            }
        }
        let info = scanInfo()
        let prompt = SystemPromptRenderer.render(template: services.systemPromptTemplate, scanAgeSeconds: info?.ageSeconds, scannedRoot: info?.root)
        let config = AssistantConfig(
            claude: installation,
            workingDirectory: services.directory,
            helperURL: services.helperURL,
            socketPath: server.socketPath,
            model: settings.assistantModel,
            maxTurns: settings.assistantMaxTurns,
            blockAPIKeys: settings.blockAPIKeys
        )
        Self.ensurePrivateDirectory(services.directory)
        try SystemPromptRenderer.write(prompt, to: config.resolvedSystemPromptURL)
        let session = ClaudeSession(config: config, thread: thread, resume: resume, ipcServer: server)
        self.session = session
        sessionThread = thread
        sawInit = false
        let events = session.events
        eventsTask = Task { [weak self, weak session] in
            for await event in events {
                guard let self, let session else { return }
                self.handle(event, from: session)
            }
        }
        try session.start()
        return session
    }

    private func ensureServer(_ services: AssistantServices) throws -> IPCServer {
        if let server { return server }
        guard let handler else { throw AssistantSessionError.notStarted }
        Self.ensurePrivateDirectory(services.ipcDirectory)
        let server = IPCServer(directory: services.ipcDirectory, handler: handler, peerPolicy: services.peerPolicy)
        try server.start()
        self.server = server
        return server
    }

    /// Closes the current session's stdin (thread switch, idle, settings change).
    private func endSession() {
        idleTask?.cancel()
        session?.close()
        session = nil
        sessionThread = nil
        if isResponding {
            isResponding = false
            finishStreaming()
        }
    }

    private func handle(_ event: StreamEvent, from source: ClaudeSession) {
        let isCurrent = source === session
        switch event {
        case .initialized(let info):
            guard isCurrent, !sawInit else { return }
            sawInit = true
            keySource = info.apiKeySource
            canStop = info.supportsInterrupt
            if !info.version.isEmpty, var known = installation, known.version == nil {
                known.version = info.version
                installation = known
            }
            if !info.isDiskServerConnected {
                errorDetails = source.stderrTail
                append(.error(L10n.diskToolsNotConnected))
            }
        case .messageStart:
            guard isCurrent else { return }
            finishStreaming()
            messageHadText = false
        case .textDelta(let text):
            guard isCurrent, !text.isEmpty else { return }
            messageHadText = true
            appendStreaming(text)
        case .toolUseStart(let id, let name):
            guard isCurrent else { return }
            finishStreaming()
            toolStarts[id] = Date()
            toolInputs[id] = ""
            append(.tool(ToolActivity(id: id, name: Self.shortToolName(name), state: .running)))
        case .toolInputDelta(let id, let partial):
            guard isCurrent, var input = toolInputs[id], input.utf8.count < 4096 else { return }
            input += partial
            toolInputs[id] = input
        case .blockStop:
            guard isCurrent else { return }
            finishStreaming()
            for (id, input) in toolInputs where !input.isEmpty {
                updateTool(id) { $0.detail = Self.summarize(arguments: input) }
                toolInputs[id] = nil
            }
        case .assistantMessage(let blocks):
            guard isCurrent else { return }
            for block in blocks {
                switch block {
                case .text(let text) where !messageHadText && !text.isEmpty:
                    append(.assistant(text: text, isStreaming: false))
                case .toolUse(let id, let name, let input) where !items.contains(where: { Self.toolID(of: $0) == id }):
                    toolStarts[id] = Date()
                    append(.tool(ToolActivity(id: id, name: Self.shortToolName(name), detail: Self.summarize(arguments: input), state: .running)))
                default:
                    break
                }
            }
        case .toolResult(let id, _, let isError):
            let duration = toolStarts[id].map { Int(Date().timeIntervalSince($0) * 1000) }
            toolStarts[id] = nil
            updateTool(id) {
                $0.state = isError ? .failed : .succeeded
                $0.durationMs = duration
            }
        case .apiRetry(let attempt, let max, _, _, let error):
            guard isCurrent else { return }
            if error == "authentication_failed" {
                availability = .notSignedIn
                append(.error(L10n.notSignedIn))
                return
            }
            let kind = ChatItem.Kind.notice(L10n.retrying(attempt, max))
            if let retryItem, let index = items.firstIndex(where: { $0.id == retryItem }) {
                items[index].kind = kind
            } else {
                let notice = ChatItem(kind: kind)
                retryItem = notice.id
                items.append(notice)
            }
        case .result(let result):
            guard isCurrent else { return }
            turnEnded(result)
        case .refused(let reason):
            guard isCurrent else { return }
            showRefusal(reason)
        case .processExited(let status):
            guard isCurrent else { return }
            session = nil
            sessionThread = nil
            finishStreaming()
            isResponding = false
            markRunningTools(.failed)
            if status != 0, refusal == nil {
                errorDetails = source.stderrTail
                append(.error(L10n.sessionCrashed))
                canRetry = lastUserMessage != nil
            }
        case .status, .thinkingDelta, .thinkingTokens, .messageDelta, .controlResponse, .unknown:
            break
        }
        if isCurrent { touchIdle() }
    }

    private func turnEnded(_ result: TurnResult) {
        finishStreaming()
        isResponding = false
        markRunningTools(.failed)
        retryItem = nil
        if let active, let store, let record = try? store.recordTurn(thread: active, result: result) {
            if let index = threads.firstIndex(where: { $0.id == active }) { threads[index] = record }
            usage = Self.usage(of: record)
            let base = guardBase[active] ?? 0
            let costBase = costGuardBase[active] ?? 0
            let budget = settings().assistantBudgetCents
            let overBudget = budget > 0 && record.estimatedCostCents - costBase >= budget
            if record.totalTokens - base > settings().assistantTokenGuard || overBudget {
                guardReached = true
                append(.notice(L10n.guardReached))
            }
        }
        switch result.subtype {
        case "success":
            if !messageHadText, let text = result.text, !text.isEmpty, !items.contains(where: { Self.assistantText(of: $0) == text }) {
                append(.assistant(text: text, isStreaming: false))
            }
        case "error_max_turns":
            canContinue = true
            append(.notice(L10n.stoppedAfterSteps(result.numTurns)))
        default:
            if stopRequested {
                append(.notice(L10n.stopped))
            } else if result.isError {
                let text = (result.text ?? "").lowercased()
                if result.apiErrorStatus == 401 || text.contains("authentication") || text.contains("/login") || text.contains("not logged in") || text.contains("invalid api key") {
                    availability = .notSignedIn
                    append(.error(L10n.notSignedIn))
                } else if text.contains("usage limit") || text.contains("limit reached") || result.apiErrorStatus == 429 {
                    append(.error(L10n.usageLimit))
                } else {
                    append(.error(L10n.genericTurnError))
                }
            }
        }
        stopRequested = false
    }

    private func showRefusal(_ reason: SessionRefusal) {
        finishStreaming()
        isResponding = false
        let card = AssistantRefusal(refusal: reason, title: L10n.refusalTitle, reason: L10n.refusalReason(reason.keyOrigin), advice: L10n.refusalAdvice)
        refusal = card
        append(.notice(card.title))
    }

    // MARK: Transcript helpers

    private func append(_ kind: ChatItem.Kind) {
        flushPendingText()
        items.append(ChatItem(kind: kind))
    }

    /// Streamed text is applied at most about 20 times per second, so a long reply does not
    /// re-render the transcript for every token. The first piece shows at once.
    private func appendStreaming(_ text: String) {
        pendingText += text
        guard streamingItem != nil else {
            flushPendingText()
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flushPendingText()
        }
    }

    private func flushPendingText() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        if let streamingItem, let index = items.lastIndex(where: { $0.id == streamingItem }),
           case .assistant(let existing, true) = items[index].kind {
            items[index].kind = .assistant(text: existing + text, isStreaming: true)
        } else {
            let item = ChatItem(kind: .assistant(text: text, isStreaming: true))
            streamingItem = item.id
            items.append(item)
        }
    }

    private func finishStreaming() {
        flushPendingText()
        guard let streamingItem else { return }
        self.streamingItem = nil
        if let index = items.lastIndex(where: { $0.id == streamingItem }), case .assistant(let text, true) = items[index].kind {
            items[index].kind = .assistant(text: text, isStreaming: false)
        }
    }

    private func updateTool(_ id: String, _ change: (inout ToolActivity) -> Void) {
        guard let index = items.lastIndex(where: { Self.toolID(of: $0) == id }), case .tool(var activity) = items[index].kind else { return }
        change(&activity)
        items[index].kind = .tool(activity)
    }

    private func markRunningTools(_ state: ToolActivity.State) {
        for index in items.indices {
            if case .tool(var activity) = items[index].kind, activity.state == .running {
                activity.state = state
                items[index].kind = .tool(activity)
            }
        }
        toolStarts.removeAll()
        toolInputs.removeAll()
    }

    private func saveTranscript() {
        guard let active else { return }
        transcripts[active] = items
    }

    private func resetTurnFlags() {
        refusal = nil
        canRetry = false
        canContinue = false
        guardReached = false
        errorDetails = nil
        lastUserMessage = nil
        streamingItem = nil
        retryItem = nil
    }

    private func touchIdle() {
        guard let services else { return }
        idleTask?.cancel()
        let timeout = services.idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, !self.isResponding, self.session != nil else { return }
            self.endSession()
        }
    }

    static func shortToolName(_ name: String) -> String {
        let prefix = "mcp__\(ToolCatalog.serverName)__"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    static func toolID(of item: ChatItem) -> String? {
        if case .tool(let activity) = item.kind { activity.id } else { nil }
    }

    static func assistantText(of item: ChatItem) -> String? {
        if case .assistant(let text, _) = item.kind { text } else { nil }
    }

    /// Short "key: value" summary of tool arguments for the Advanced view.
    static func summarize(arguments json: String) -> String {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return "" }
        return summarize(arguments: value)
    }

    static func summarize(arguments value: JSONValue) -> String {
        guard case .object(let object) = value else { return "" }
        let parts = object.keys.sorted().compactMap { key -> String? in
            switch object[key] {
            case .string(let text)?: return "\(key): \(text)"
            case .int(let number)?: return "\(key): \(number)"
            case .bool(let flag)?: return "\(key): \(flag)"
            case .array(let list)?: return "\(key): \(list.count)"
            default: return nil
            }
        }
        let joined = parts.joined(separator: ", ")
        return joined.count > 160 ? String(joined.prefix(159)) + "..." : joined
    }

    static func usage(of record: ThreadRecord) -> UsageSummary {
        UsageSummary(inputTokens: record.inputTokens, outputTokens: record.outputTokens, costCents: record.estimatedCostCents, turns: record.turns)
    }

    static func ensurePrivateDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
