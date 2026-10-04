import AppKit
import Combine
import Foundation
import SwiftUI
import MuesliCore

enum HushAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var appKit: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}

/// The encrypted vault is authoritative. Native SQLCipher rows are a projection,
/// never an independent editor or a plaintext copy of the secure meeting store.
@MainActor
final class HushMuesliBridge {
    let model: AppModel
    let calendar: CalendarFeed
    private weak var controller: MuesliController?
    private var mappings: [UUID: Int64] = [:]
    private var secureIDs: [Int64: UUID] = [:]
    private var observation: AnyCancellable?
    private var isNavigating = false
    private var lastRecording = false
    private var preparedBackend: BackendOption?
    private var preparedConfig: AppConfig?
    private var projectedMeetings: [Meeting]?
    private var projectedRecordingID: UUID?

    init(model: AppModel, controller: MuesliController) throws {
        self.model = model
        self.controller = controller
        calendar = CalendarFeed(enabled: !model.testMode)
        controller.hushModel = model
        model.settings.model = controller.config.nearAIModel
        controller.appState.hushAppearance = HushAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "System") ?? .system
        try controller.dictationStore.migrateIfNeeded()
        model.onStateChanged = { [weak self] in try self?.synchronize() }
        model.onNavigate = { [weak self] screen in self?.navigate(screen) }
        model.validatePresentation = { [weak controller] in
            guard let controller else { throw AppError("Native controller is unavailable") }
            return try controller.validateHushPresentation()
        }
        model.nativeDiscardRecording = { [weak controller] in
            guard let controller else { throw AppError("Native controller is unavailable") }
            try await controller.discardHushRecording()
        }
        model.nativeSearch = { [weak controller] query in
            guard let controller else { throw AppError("Native controller is unavailable") }
            controller.performSearch(query: query)
            await controller.waitForHushSearch()
            if let error = controller.appState.hushSearchError { throw AppError(error) }
            return controller.appState.searchResultMeetings.map(\.title).joined(separator: "\n")
        }
        model.nativeLocalTranscription = { [weak self] url, modelName in
            guard let self, let controller = self.controller, self.model.testMode,
                  !self.model.recording, !self.model.busy, modelName == BackendOption.whisperTinyEnglish.model else {
                throw AppError("Explicit native local transcription requires an idle E2E run and tiny.en.")
            }
            let previousSelection = controller.selectedMeetingTranscriptionBackend
            let previousPrepare = self.model.prepareTranscription
            let previousTranscribe = self.model.transcribeChunk
            let previousPreparedBackend = self.preparedBackend
            let previousPreparedConfig = self.preparedConfig
            controller.selectMeetingTranscriptionBackend(.whisperTinyEnglish, requireDownloaded: false)
            self.configureNativeTranscription(allowModelDownload: true)
            defer {
                self.model.prepareTranscription = previousPrepare
                self.model.transcribeChunk = previousTranscribe
                self.preparedBackend = previousPreparedBackend
                self.preparedConfig = previousPreparedConfig
                controller.selectMeetingTranscriptionBackend(previousSelection, requireDownloaded: false)
            }
            try await self.model.importAudio(url, title: "Native local transcription")
            guard let meeting = self.model.selected else { throw AppError("Local native transcript was not persisted.") }
            return meeting.segments.lazy.map(\.text).joined(separator: "\n")
        }
        model.nativeShortcut = { [weak controller] name in
            guard let controller, let window = controller.hushPresentationWindow else {
                throw AppError("Native dashboard window is unavailable")
            }
            guard ["sidebar", "search"].contains(name) else { throw AppError("Unknown native shortcut") }
            let wasCollapsed = controller.appState.hushSidebarCollapsed
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let character = name == "sidebar" ? "\\" : "k"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: name == "sidebar" ? 42 : 40) else {
                throw AppError("Native shortcut event could not be created")
            }
            NSApp.postEvent(event, atStart: false)
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(25))
                window.contentView?.layoutSubtreeIfNeeded()
                let state = controller.appState
                if name == "sidebar" {
                    let expectedCollapsed = !wasCollapsed
                    let measured = expectedCollapsed ? abs(state.hushSidebarWidth - 68) < 1 : state.hushSidebarWidth >= 240
                    if state.hushSidebarCollapsed == expectedCollapsed && measured { break }
                } else if state.hushSearchFocused, (window.firstResponder as? NSTextView)?.isFieldEditor == true { break }
            }
            let state = controller.appState
            if name == "sidebar" {
                guard state.hushSidebarCollapsed != wasCollapsed,
                      state.hushSidebarCollapsed ? abs(state.hushSidebarWidth - 68) < 1 : state.hushSidebarWidth >= 240 else {
                    throw AppError("Command-backslash did not change the actual native sidebar layout (collapsed=\(state.hushSidebarCollapsed), width=\(state.hushSidebarWidth), keyWindow=\(window.isKeyWindow))")
                }
            } else {
                guard !state.hushSidebarCollapsed, state.hushSearchFocused,
                      (window.firstResponder as? NSTextView)?.isFieldEditor == true else {
                    throw AppError("Command-K did not focus the actual native search field")
                }
            }
            let result: [String: Any] = ["shortcut": name, "sidebarCollapsed": state.hushSidebarCollapsed,
                "sidebarWidth": Double(state.hushSidebarWidth), "searchFocused": state.hushSearchFocused]
            return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
        }
        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.lastRecording != self.model.recording {
                    self.lastRecording = self.model.recording
                    do { try self.synchronize() } catch { self.model.error = error.localizedDescription }
                }
                self.syncLiveState()
            }
        }
        try synchronize()
        navigate(model.screen)
        if !model.testMode { configureNativeTranscription() }
    }

    static func transcript(_ meeting: Meeting) -> String {
        meeting.segments.lazy.filter { !$0.text.isEmpty }.map { segment in
            let start = segment.start.isFinite ? max(0, min(segment.start, Double(Int32.max))) : 0
            let seconds = Int(start)
            let timestamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            let speaker = segment.channel == .me ? "You" : "Others"
            return "[\(timestamp)] \(speaker): \(segment.text)"
        }.joined(separator: "\n")
    }
    func configureNativeTranscription(allowModelDownload: Bool = false) {
        model.prepareTranscription = { [weak self] in
            guard let self, let controller = self.controller else { throw AppError("Native transcription runtime is unavailable") }
            let backend = controller.selectedMeetingTranscriptionBackend
            let config = controller.config
            if backend.backend == BackendOption.nearAI.backend {
                try await self.model.verify()
            } else {
                guard backend.supportsMeetingTranscription, allowModelDownload || backend.isDownloaded else {
                    throw AppError("Download \(backend.label) in Models before recording, or select NEAR AI in native meeting settings.")
                }
                try await controller.transcriptionCoordinator.preloadRequired(
                    backend: backend, enablePostProcessor: false, includeMeetingHelpers: false,
                    appleSpeechLanguage: config.resolvedAppleSpeechLanguage)
            }
            try Task.checkCancellation()
            self.preparedBackend = backend
            self.preparedConfig = config
        }
        model.transcribeChunk = { [weak self] chunk in
            guard let self, let controller = self.controller,
                  let backend = self.preparedBackend, let config = self.preparedConfig else {
                throw AppError("Prepare the native transcription model before processing encrypted audio.")
            }
            if backend.backend == BackendOption.nearAI.backend {
                return try await self.model.client.transcribe(chunk)
            }
            let samples = try HushLocalAudio.samples(from: chunk)
            let result = try await controller.transcriptionCoordinator.transcribeMeetingChunk(
                samples: samples, backend: backend, cohereLanguage: config.resolvedCohereLanguage,
                bodhanLanguage: config.resolvedBodhanLanguage, bodhanOutputMode: config.resolvedBodhanOutputMode,
                whisperLanguage: config.resolvedWhisperLanguage, qwen3AsrLanguage: config.resolvedQwen3AsrLanguage,
                parakeetLanguage: config.resolvedParakeetLanguage, appleSpeechLanguage: config.resolvedAppleSpeechLanguage)
            return TranscriptSegment(chunkID: chunk.id, channel: chunk.channel,
                start: chunk.start, end: chunk.end, text: result.text)
        }
    }


    func synchronize() throws {
        guard let controller else { throw AppError("Native controller is unavailable") }
        let recordingID = model.recording ? model.recordingMeetingID : nil
        if projectedRecordingID == recordingID, let projectedMeetings,
           projectedMeetings.count == model.meetings.count,
           zip(projectedMeetings, model.meetings).allSatisfy({ previous, current in
               previous.id == current.id && previous.title == current.title
                   && previous.startedAt == current.startedAt && previous.segments == current.segments
                   && previous.scratchNotes == current.scratchNotes && previous.summary == current.summary
           }) {
            // A refresh is an authenticated read, not a reason to rewrite the
            // projection. This also keeps unchanged notes readable during a
            // failed start on a read-only vault.
            self.projectedMeetings = model.meetings
            return
        }
        for meeting in model.meetings {
            let duration = meeting.segments.lazy.map(\.end).max() ?? 0
            _ = try controller.dictationStore.upsertHushMeeting(
                id: meeting.id, title: meeting.title, startTime: meeting.startedAt,
                endTime: meeting.startedAt.addingTimeInterval(duration),
                rawTranscript: Self.transcript(meeting), formattedNotes: meeting.summary,
                manualNotes: meeting.scratchNotes, status: model.recording && model.recordingMeetingID == meeting.id ? .recording : .completed
            )
        }
        try controller.dictationStore.deleteHushMeetings(except: Set(model.meetings.map(\.id)))
        let refreshedMappings = try controller.dictationStore.hushMeetingMappings()
        if refreshedMappings != mappings {
            mappings = refreshedMappings
            secureIDs = Dictionary(uniqueKeysWithValues: mappings.lazy.map { ($0.value, $0.key) })
        }
        controller.syncAppState()
        projectedMeetings = model.meetings
        projectedRecordingID = recordingID
    }

    func syncLiveState() {
        guard let controller else { return }
        controller.appState.isMeetingRecording = model.recording
        controller.appState.isMeetingRecordingPaused = model.recordingPaused
        controller.appState.isMeetingStarting = model.busy && !model.recording
        controller.appState.meetingStartStatus = model.busy ? model.status : nil
        controller.appState.liveMeetingTranscriptOwnerID = model.recording ? model.recordingMeetingID.flatMap { mappings[$0] } : nil
        // Hush's acknowledged live segments are already in the encrypted row
        // used as the native live view's prefix; adding them again duplicates it.
        controller.appState.liveMeetingTranscript = ""
    }

    func navigate(_ screen: AppModel.Screen) {
        guard !isNavigating, let controller else { return }
        isNavigating = true
        defer { isNavigating = false }
        let state = controller.appState
        controller.clearSearch()
        switch screen {
        case .home:
            state.selectedTab = .timeline
            state.meetingsNavigationState = .browser
            state.selectedMeetingID = nil
            state.selectedMeetingRecord = nil
        case .chat:
            state.selectedTab = .chat
            state.meetingsNavigationState = .browser
            state.selectedMeetingID = nil
            state.selectedMeetingRecord = nil
        case .meeting:
            guard let id = model.selectedID.flatMap({ mappings[$0] }) else { return }
            state.selectedTab = .meetings
            state.meetingDetailReturnDestination = .meetings
            state.selectedMeetingID = id
            state.selectedMeetingRecord = controller.meeting(id: id)
            state.meetingsNavigationState = .document(id)
        }
        syncLiveState()
    }

    func contains(_ id: Int64) -> Bool { secureIDs[id] != nil }
    func nativeID(for uuid: UUID) -> Int64? { mappings[uuid] }
    func secureID(_ id: Int64) -> UUID? { secureIDs[id] }
    func secureMeeting(id: Int64) -> Meeting? {
        guard let uuid = secureID(id) else { return nil }
        return model.meetings.first(where: { $0.id == uuid })
    }
    func selectNativeMeeting(id: Int64) {
        guard let uuid = secureID(id) else { return }
        isNavigating = true
        defer { isNavigating = false }
        model.selectedID = uuid
        model.screen = .meeting
    }

    @discardableResult
    func edit(id: Int64, change: (inout Meeting) -> Void) -> Bool {
        guard let uuid = secureID(id), var meeting = model.meetings.first(where: { $0.id == uuid }) else { return false }
        change(&meeting)
        do { try model.save(meeting) }
        catch { model.error = error.localizedDescription }
        return true
    }

    @discardableResult
    func delete(id: Int64) -> Bool {
        guard let uuid = secureID(id) else { return false }
        do { try model.deleteMeeting(uuid) }
        catch { model.error = error.localizedDescription }
        return true
    }

    func saveSummary(source: MeetingRecord, snapshot: Meeting?, notes: String, embed: Bool) async throws {
        guard let snapshot, let uuid = secureID(source.id),
              var latest = try model.vault.meetings().first(where: { $0.id == uuid }),
              latest.segments == snapshot.segments, latest.scratchNotes == snapshot.scratchNotes,
              latest.summary == snapshot.summary,
              Self.transcript(latest) == source.rawTranscript,
              latest.scratchNotes == source.manualNotes else {
            throw AppError("Meeting changed during summarization; retry to include the latest notes")
        }
        let segments = latest.segments
        let embeddings: [[Float]]
        if embed { embeddings = try await model.client.embed(segments.map(\.text)) }
        else { embeddings = latest.embeddings }
        guard let current = try model.vault.meetings().first(where: { $0.id == uuid }),
              current.segments == segments, current.scratchNotes == source.manualNotes,
              current.summary == snapshot.summary else {
            throw AppError("Meeting changed during summarization; retry to include the latest notes")
        }
        latest = current
        latest.summary = notes
        latest.embeddings = embeddings
        try model.save(latest)
    }
}

extension MuesliController {
    func canUseDictationProvider(_ provider: DictationProvider) -> Bool {
        hushModel == nil || provider == .local
    }

    func discardHushRecording(id: UUID? = nil) async throws {
        guard let model = hushModel, let recordingID = id ?? model.recordingMeetingID else {
            throw AppError("No secure recording is available to discard.")
        }
        try await model.stopRecording()
        try model.deleteMeeting(recordingID)
    }

    func configureHushNativeTranscription() {
        hushBridge?.configureNativeTranscription()
    }

    func showHushChat() {
        hushModel?.screen = .chat
        appState.selectedTab = .chat
    }

    func setHushAppearance(_ appearance: HushAppearance) {
        appState.hushAppearance = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
        applyAppThemeAppearance()
    }

    var hushTemplateSnapshot: MeetingTemplateSnapshot {
        if let meeting = appState.selectedMeeting, hushBridge?.contains(meeting.id) == true {
            return meetingTemplateSnapshot(for: meeting)
        }
        return defaultMeetingTemplate()
    }

    func setHushTemplate(id: String) {
        if id == "hush-custom", !config.customMeetingTemplates.contains(where: { $0.id == id }) {
            updateConfig {
                $0.customMeetingTemplates.append(CustomMeetingTemplate(id: id, name: "Custom", prompt: hushModel?.settings.customTemplate ?? ""))
            }
        }
        guard let snapshot = MeetingTemplates.resolveExactSnapshot(id: id, customTemplates: config.customMeetingTemplates) else {
            hushModel?.error = "The selected native template is unavailable."
            return
        }
        updateDefaultMeetingTemplate(id: id)
        applyHushTemplateSnapshot(snapshot)
    }

    func setHushCustomTemplate(prompt: String) {
        let selection = hushTemplateSnapshot
        guard selection.kind == .custom else { return }
        updateConfig { config in
            if let index = config.customMeetingTemplates.firstIndex(where: { $0.id == selection.id }) {
                config.customMeetingTemplates[index].prompt = prompt
            } else {
                config.customMeetingTemplates.append(CustomMeetingTemplate(id: selection.id, name: selection.name, prompt: prompt))
            }
        }
        guard let snapshot = MeetingTemplates.resolveExactSnapshot(id: selection.id, customTemplates: config.customMeetingTemplates) else { return }
        applyHushTemplateSnapshot(snapshot)
    }

    private func applyHushTemplateSnapshot(_ snapshot: MeetingTemplateSnapshot) {
        hushModel?.settings.template = "Custom"
        hushModel?.settings.customTemplate = snapshot.prompt
        if let meeting = appState.selectedMeeting, hushBridge?.contains(meeting.id) == true {
            do {
                try dictationStore.updateMeetingSummary(id: meeting.id, title: meeting.title,
                    formattedNotes: meeting.formattedNotes, selectedTemplateID: snapshot.id,
                    selectedTemplateName: snapshot.name, selectedTemplateKind: snapshot.kind,
                    selectedTemplatePrompt: snapshot.prompt)
                syncAppState()
            } catch { hushModel?.error = error.localizedDescription }
        }
    }

    func validateHushPresentation() throws -> String {
        guard let model = hushModel, let bridge = hushBridge,
              let window = hushPresentationWindow, window.contentView is NSHostingView<DashboardRootView>,
              window.title == "Hush" else { throw AppError("Actual Hush Muesli dashboard window is missing") }
        window.contentView?.layoutSubtreeIfNeeded()
        for meeting in model.meetings {
            guard let nativeID = try dictationStore.hushMeetingMappings()[meeting.id],
                  let row = try dictationStore.meeting(id: nativeID),
                  row.title == meeting.title,
                  row.rawTranscript == HushMuesliBridge.transcript(meeting),
                  row.manualNotes == meeting.scratchNotes,
                  row.formattedNotes == meeting.summary else {
                throw AppError("Native encrypted projection does not match the secure meeting")
            }
        }
        guard try dictationStore.hushMeetingMappings().count == model.meetings.count else {
            throw AppError("Native meeting count differs from the secure vault")
        }
        for row in appState.meetingRows {
            guard let uuid = bridge.secureID(row.id) else { continue }
            guard let secure = model.meetings.first(where: { $0.id == uuid }),
                  row.rawTranscript == HushMuesliBridge.transcript(secure),
                  row.manualNotes == secure.scratchNotes, row.formattedNotes == secure.summary else {
                throw AppError("Native visible meeting rows are stale")
            }
        }
        let screen: String
        if appState.isSearchActive, appState.meetingsNavigationState == .browser {
            screen = "search"
        } else if case .document(let nativeID) = appState.meetingsNavigationState {
            screen = "meeting"
            guard model.screen == .meeting, let selected = model.selected, let row = appState.selectedMeeting,
                  row.id == nativeID, bridge.secureID(row.id) == selected.id,
                  row.rawTranscript == HushMuesliBridge.transcript(selected),
                  row.manualNotes == selected.scratchNotes, row.formattedNotes == selected.summary else {
                throw AppError("Native meeting detail is stale")
            }
        } else if appState.selectedTab == .chat {
            screen = "chat"
            guard model.screen == .chat else { throw AppError("Native chat navigation is stale") }
        } else if appState.selectedTab == .timeline || appState.selectedTab == .meetings {
            screen = "home"
            guard model.screen == .home else { throw AppError("Native home navigation is stale") }
        } else {
            screen = appState.selectedTab.rawValue
        }
        var metadata: [String: Any] = ["ui": "Muesli", "meetingCount": model.meetings.count, "screen": screen, "synchronized": true]
        let effectiveAppearance = window.effectiveAppearance
        metadata["appearancePreference"] = appState.hushAppearance.rawValue
        metadata["effectiveAppearance"] = effectiveAppearance.name.rawValue
        metadata["colorScheme"] = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "Dark" : "Light"
        guard let content = window.contentView else {
            throw AppError("The actual native dashboard could not be rendered for appearance verification.")
        }
        let sampleBounds = NSRect(x: content.bounds.maxX - 8, y: content.bounds.midY, width: 1, height: 1)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: sampleBounds) else {
            throw AppError("The actual native dashboard could not be rendered for appearance verification.")
        }
        content.cacheDisplay(in: sampleBounds, to: bitmap)
        guard let pixel = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            throw AppError("The actual native dashboard background pixel is unavailable.")
        }
        metadata["renderedBackgroundRGBA"] = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent]
        metadata["renderedBackgroundLuminance"] = 0.2126 * pixel.redComponent + 0.7152 * pixel.greenComponent + 0.0722 * pixel.blueComponent
        if let id = model.selectedID { metadata["selectedMeetingID"] = id.uuidString }
        return String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
    }
}
