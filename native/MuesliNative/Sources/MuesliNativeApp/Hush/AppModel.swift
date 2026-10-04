import AppKit
import Foundation
import SwiftUI

/// Audio callbacks finish their encrypted writes before returning to the chunker.
/// Failed writes stay in memory until stop retries them or refuses termination.
private final class RecordingDelivery: @unchecked Sendable {
    let meetingID: UUID
    private let vault: Vault
    private let lock = NSLock()
    private var failedChunks: [AudioChunk] = []

    init(vault: Vault, meetingID: UUID) {
        self.vault = vault
        self.meetingID = meetingID
    }

    func persist(_ chunk: AudioChunk) -> Error? {
        lock.lock(); defer { lock.unlock() }
        do { try vault.appendPendingChunks([chunk], meetingID: meetingID); return nil }
        catch {
            failedChunks.append(chunk)
            return error
        }
    }

    func retryFailedChunks() throws {
        lock.lock(); defer { lock.unlock() }
        guard !failedChunks.isEmpty else { return }
        try vault.appendPendingChunks(failedChunks, meetingID: meetingID)
        failedChunks.removeAll()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedID: UUID? {
        didSet {
            if selectedID != oldValue { onNavigate?(screen) }
        }
    }
    @Published var status = "Ready"
    @Published var error: String?
    @Published var recording = false {
        didSet { if !recording { recordingPaused = false } }
    }
    @Published private(set) var recordingPaused = false
    @Published var busy = false
    @Published var searchText = ""
    @Published var answer = ""
    @Published var detailTab = "Transcript"
    enum Screen { case home, chat, meeting }
    /// Window navigation only; `selectedID` stays the action target that refresh() keeps populated.
    @Published var screen = Screen.home {
        didSet {
            onNavigate?(screen)
        }
    }
    @Published var trust = TrustStatus(state: "unverified", detail: "No verification performed", verifiedAt: nil)
    @Published var quotaValue: Quota?
    @Published var settings = AppSettings()
    /// The native shell mirrors only authenticated state; failures propagate to callers.
    var onStateChanged: (() throws -> Void)?
    /// Also updates native selection when the action target changes within one screen.
    var onNavigate: ((Screen) -> Void)?
    /// Binary E2E validates the same native presentation used by the interactive shell.
    var validatePresentation: (() throws -> String)?
    var nativeSearch: ((String) async throws -> String)?
    var nativeShortcut: ((String) async throws -> String)?
    /// Native provider preparation must establish its boundary before private audio is captured.
    var prepareTranscription: (() async throws -> Void)?
    /// Providers consume existing in-memory chunks; encrypted persistence remains owned here.
    var transcribeChunk: ((AudioChunk) async throws -> TranscriptSegment)?
    var nativeLocalTranscription: ((URL, String) async throws -> String)?
    var nativeDiscardRecording: (() async throws -> Void)?
    let testMode: Bool
    let root: URL
    let vault: Vault
    var client: InferenceClient
    let recorder: AudioRecorder
    private var startingRecording = false
    private var flushTask: Task<Void, Error>?
    private var recordingAttempt: UUID?
    private var latestRecordingAttempt: UUID?
    private var captureDelivery: RecordingDelivery?
    private var provisionalMeeting: Meeting?
    private var stopTask: Task<Void, Error>?
    private var preparingToQuit = false

    init(root: URL, endpoint: URL, testMode: Bool, keychainVault: Bool = false, syntheticMicrophone: Bool = false) throws {
        guard !syntheticMicrophone || testMode else {
            throw AppError("Synthetic microphone is restricted to explicit E2E verification")
        }
        self.root = root
        self.testMode = testMode
        recorder = AudioRecorder(syntheticMicrophone: syntheticMicrophone)
        vault = try Vault(directory: root, testMode: testMode && !keychainVault)
        let apiKey = try (testMode ? "" : Credentials.load(endpoint: endpoint))
        client = InferenceClient(baseURL: endpoint, apiKey: apiKey, testMode: testMode)
        settings.endpointURL = endpoint.absoluteString
        meetings = try vault.meetings()
        selectedID = meetings.first?.id
    }
    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var recordingMeetingID: UUID? { captureDelivery?.meetingID }
    func refresh() throws {
        meetings = try vault.meetings().sorted { $0.startedAt > $1.startedAt }
        if selectedID == nil { selectedID = meetings.first?.id }
        try onStateChanged?()
    }
    func save(_ meeting: Meeting) throws { try vault.save(meeting); try refresh(); selectedID = meeting.id }
    func setNotes(_ notes: String) {
        guard var meeting = selected else { return }
        meeting.scratchNotes = notes
        do { try save(meeting) } catch { self.error = error.localizedDescription }
    }
    func verify() async throws { trust = try await client.verify() }
    func importAudio(_ url: URL, title: String) async throws {
        try await prepareTranscription?()
        let chunks = try AudioRecorder.chunkFile(url)
        guard !chunks.isEmpty else { throw AppError("Audio contains no speech or usable sound") }
        let meeting = Meeting(title: title)
        try save(meeting)
        screen = .meeting
        try vault.appendPendingChunks(chunks, meetingID: meeting.id)
        try await flushQueue()
    }
    func flushQueue() async throws {
        guard !preparingToQuit else { throw CancellationError() }
        if let flushTask { return try await flushTask.value }
        let task = Task { @MainActor in
            defer { self.flushTask = nil }
            try await self.drainQueue()
        }
        flushTask = task
        try await task.value
    }
    private func drainQueue() async throws {
        var transcriptionPrepared = false
        while let pending = try vault.pendingChunks().first {
            try Task.checkCancellation()
            guard let before = try vault.meetings().first(where: { $0.id == pending.meetingID }) else {
                try vault.delete(pending.meetingID)
                continue
            }
            guard let chunk = pending.chunks.first else { continue }
            let segment: TranscriptSegment
            if let completed = before.segments.first(where: { $0.chunkID == chunk.id }) {
                segment = completed
            } else {
                if !transcriptionPrepared {
                    try await prepareTranscription?()
                    transcriptionPrepared = true
                    try Task.checkCancellation()
                }
                if let transcribeChunk {
                    segment = try await transcribeChunk(chunk)
                } else {
                    segment = try await client.transcribe(chunk)
                }
            }
            try Task.checkCancellation()
            try vault.commitTranscription(segment, meetingID: pending.meetingID)
            try refresh()
        }
        if !recording { status = "Transcript saved" }
    }
    func startRecording(title: String? = nil) async throws {
        guard !recording, !startingRecording, stopTask == nil, captureDelivery == nil, !preparingToQuit else {
            throw AppError("Recording is already active, stopping, or awaiting secure storage")
        }
        startingRecording = true
        let attempt = UUID()
        recordingAttempt = attempt
        latestRecordingAttempt = attempt
        defer {
            startingRecording = false
            if recordingAttempt == attempt { recordingAttempt = nil }
        }
        if let prepareTranscription {
            try await prepareTranscription()
        } else {
            try await verify()
        }
        try await recorder.authorizeMicrophone()
        guard recordingAttempt == attempt, !preparingToQuit else { throw AppError("Recording was cancelled before capture started") }
        let meeting = Meeting(title: title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))")
        let delivery = RecordingDelivery(vault: vault, meetingID: meeting.id)
        captureDelivery = delivery
        provisionalMeeting = meeting
        do {
            try save(meeting)
            screen = .meeting
            recorder.onFailure = { [weak self, delivery] message in
                Task { @MainActor [weak self] in
                    guard let self, self.latestRecordingAttempt == attempt, self.captureDelivery === delivery else { return }
                    self.error = message
                    do { try await self.finishCapture() }
                    catch {
                        guard self.latestRecordingAttempt == attempt else { return }
                        self.error = error.localizedDescription
                    }
                    guard self.latestRecordingAttempt == attempt else { return }
                    self.recording = false
                    self.status = self.captureDelivery == nil
                        ? "Recording stopped after an audio-device error"
                        : "Recording stopped; audio could not be saved securely"
                }
            }
            try await recorder.start { [weak self, delivery] chunk in
                let persistenceError = delivery.persist(chunk)
                Task { @MainActor [weak self] in
                    guard let self, self.latestRecordingAttempt == attempt, self.captureDelivery === delivery, !self.preparingToQuit else { return }
                    if let persistenceError {
                        self.error = persistenceError.localizedDescription
                        self.status = "Secure audio storage failed; stopping recording"
                        do {
                            try await self.finishCapture()
                            guard self.latestRecordingAttempt == attempt else { return }
                            self.status = "Recording stopped after a secure-storage error"
                        }
                        catch {
                            guard self.latestRecordingAttempt == attempt else { return }
                            self.error = error.localizedDescription
                            self.status = "Recording stopped; audio could not be saved securely"
                        }
                        return
                    }
                    do { try self.refresh(); try await self.flushQueue() }
                    catch {
                        guard self.latestRecordingAttempt == attempt, !self.preparingToQuit, !(error is CancellationError) else { return }
                        self.error = error.localizedDescription
                        self.status = "Audio queued securely; retry when connected"
                    }
                }
            }
            guard recordingAttempt == attempt, !preparingToQuit else {
                throw AppError("Recording was cancelled while starting")
            }
            provisionalMeeting = nil
            recording = true
            status = "Recording — obtain everyone’s consent"
        } catch {
            let startError = error
            try await finishCapture()
            throw startError
        }
    }
    /// Single-flight resource stop; durable tails do not depend on UI task scheduling.
    private func finishCapture() async throws {
        if let stopTask { return try await stopTask.value }
        recordingAttempt = nil
        let delivery = captureDelivery
        let provisional = provisionalMeeting
        let task = Task { @MainActor in
            defer { self.stopTask = nil }
            var captureError: Error?
            do { try await self.recorder.stop() } catch { captureError = error }
            self.recording = false
            try delivery?.retryFailedChunks()
            if let provisional {
                let discarded = try self.vault.discardUnusedMeeting(provisional)
                if discarded, self.selectedID == provisional.id { self.selectedID = nil }
                if self.provisionalMeeting?.id == provisional.id { self.provisionalMeeting = nil }
            }
            if self.captureDelivery === delivery {
                self.captureDelivery = nil
                self.recorder.onFailure = nil
            }
            try self.refresh()
            if let captureError { throw captureError }
        }
        stopTask = task
        try await task.value
    }
    func stopRecording() async throws {
        var stopError: Error?
        do { try await finishCapture() } catch { stopError = error }
        do { try await flushQueue() } catch { if stopError == nil { stopError = error } }
        if let stopError { throw stopError }
    }
    func toggleRecordingPause() {
        guard recording, stopTask == nil, !preparingToQuit else { return }
        do {
            let paused = !recordingPaused
            try recorder.setPaused(paused)
            recordingPaused = paused
            status = paused ? "Recording paused" : "Recording — obtain everyone’s consent"
        } catch {
            self.error = error.localizedDescription
        }
    }
    /// `title` names a new recording (e.g. after a calendar event); ignored when stopping.
    func toggleRecording(title: String? = nil) {
        if recording || startingRecording || captureDelivery != nil || stopTask != nil {
            Task {
                do { try await stopRecording() } catch { self.error = error.localizedDescription }
            }
        } else {
            run { try await self.startRecording(title: title) }
        }
    }
    func prepareToQuit() async -> Bool {
        preparingToQuit = true
        flushTask?.cancel()
        do {
            if recording || startingRecording || captureDelivery != nil || stopTask != nil {
                try await finishCapture()
            }
        } catch {
            self.error = error.localizedDescription
            if captureDelivery != nil {
                latestRecordingAttempt = nil
                status = "Cannot quit: recorded audio could not be saved securely"
                _ = try? await flushTask?.value
                preparingToQuit = false
                return false
            }
        }
        // Every emitted tail has already returned from its encrypted append.
        // Upload cancellation leaves unacknowledged chunks in the vault.
        _ = try? await flushTask?.value
        return true
    }
    func summarize() async throws {
        guard let source = selected else { throw AppError("Select a meeting") }
        let template = settings.template == "Custom" ? settings.customTemplate : settings.template
        let summary = try await client.summarize(source, template: template, model: settings.model)
        let embeddings = try await client.embed(source.segments.map(\.text))
        guard var latest = try vault.meetings().first(where: { $0.id == source.id }) else { throw AppError("Meeting was deleted during summarization") }
        guard latest.segments == source.segments, latest.scratchNotes == source.scratchNotes else {
            throw AppError("Meeting changed during summarization; retry to include the latest notes")
        }
        latest.summary = summary
        latest.embeddings = embeddings
        try save(latest)
        status = "Notes enhanced"
    }
    func search(_ query: String) async throws -> [Meeting] {
        if query.isEmpty { return try vault.meetings() }
        let lexical = try vault.search(query)
        let vectors = try await client.embed([query])
        let semantic = try vault.semanticSearch(vectors.first ?? [])
        var seen = Set<UUID>()
        return (lexical + semantic).filter { seen.insert($0.id).inserted }
    }
    func ask(_ question: String) async throws {
        let relevant = try await search(question)
        answer = try await client.ask(question, meetings: Array(relevant.prefix(5)), model: settings.model)
    }
    func deleteMeeting(_ id: UUID) throws {
        guard captureDelivery?.meetingID != id else { throw AppError("Stop recording before deleting its meeting") }
        try vault.delete(id)
        if selectedID == id {
            selectedID = nil
            screen = .home
        }
        try refresh()
    }
    func deleteSelected() throws {
        guard let id = selectedID else { return }
        try deleteMeeting(id)
    }
    func backup(to url: URL, phrase: String) throws { try vault.exportBackup(to: url, recoveryPhrase: phrase) }
    func restore(from url: URL, phrase: String) throws {
        guard !recording, !startingRecording, captureDelivery == nil, stopTask == nil, flushTask == nil else {
            throw AppError("Stop recording and wait for queued transcription before restoring")
        }
        try vault.restoreBackup(from: url, recoveryPhrase: phrase)
        selectedID = nil
        screen = .home
        try refresh()
    }
    func login(_ account: String) async throws { _ = try await client.login(accountID: account); quotaValue = try await client.quota() }
    func stake(_ amount: String) async throws { quotaValue = try await client.stake(amount: amount) }
    func configure(endpoint: String, key: String) async throws {
        guard let url = URL(string: endpoint), ["https", "http"].contains(url.scheme ?? "") else { throw AppError("Invalid endpoint") }
        let candidate = InferenceClient(baseURL: url, apiKey: key, testMode: testMode)
        let verified = try await candidate.verify()
        if !testMode { try Credentials.save(key, endpoint: url) }
        client = candidate
        settings.endpointURL = endpoint
        trust = verified
    }
    func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription; status = "Action failed" }
        }
    }
}
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
