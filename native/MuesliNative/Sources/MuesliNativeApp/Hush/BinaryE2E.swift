import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import MuesliCore

struct LaunchOptions {
    let e2e: Bool
    let syntheticMicrophone: Bool
    let mock: Bool
    let keychainVault: Bool
    let root: URL?
    let endpoint: URL
    let commands: URL?
    let results: URL?
    init() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        e2e = args.contains("--e2e")
        syntheticMicrophone = args.contains("--synthetic-microphone")
        if syntheticMicrophone && !e2e {
            fputs("--synthetic-microphone requires --e2e; synthetic PCM is only an explicit verification source\n", stderr)
            exit(2)
        }
        mock = e2e || args.contains("--mock")
        keychainVault = args.contains("--keychain-vault")
        root = value("--root").map { URL(fileURLWithPath: $0, isDirectory: true) }
        endpoint = URL(string: value("--endpoint") ?? "https://cloud-api.near.ai")!
        commands = value("--commands").map { URL(fileURLWithPath: $0) }
        results = value("--results").map { URL(fileURLWithPath: $0) }
    }
}

struct E2ECommand: Decodable {
    let action: String
    var value: String?
    var path: String?
    var phrase: String?
    var expectError: Bool?
    var expectContains: String?
    var expectCount: Int?
}
struct E2EResult: Codable {
    let action: String
    let passed: Bool
    let detail: String
    let meetingCount: Int
    let segmentCount: Int
}

@MainActor
final class BinaryE2E {
    let model: AppModel
    let options: LaunchOptions
    init(model: AppModel, options: LaunchOptions) { self.model = model; self.options = options }
    private var terminateAfterResults = false
    private var quitPlayer: Process?
    private var quitMeetingID: UUID?
    private var quitStartedAt = 0.0
    private var quitRequestElapsed: Double?
    private var quitWriteDenial = false
    private var quitRefused = false
    private var quitBufferedAtRequest = false
    private var memoryTailRecovered = false
    private var deniedVaultPermissions: NSNumber?
    private var shutdownResults: [E2EResult] = []
    private var shutdownURL: URL?
    private var terminationObserver: NSObjectProtocol?
    func run() async {
        guard let commandURL = options.commands, let resultURL = options.results else {
            fputs("--e2e requires --commands and --results\n", stderr); exit(2)
        }
        var results: [E2EResult] = []
        fputs("E2E runner started\n", stderr)
        do {
            let commands = try JSONDecoder().decode([E2ECommand].self, from: Data(contentsOf: commandURL))
            guard !commands.dropLast().contains(where: { ["recordQuit", "recordQuitWriteFailure"].contains($0.action) }) else {
                throw AppError("A recording quit scenario must be the final command")
            }
            for command in commands {
                if command.expectError == true && (command.expectContains?.isEmpty ?? true) {
                    throw AppError("Negative E2E assertions require an expected failure reason")
                }
                fputs("E2E starting \(command.action)\n", stderr)
                var detail = ""
                var failed: Error?
                do { detail = try await execute(command) }
                catch {
                    failed = error
                    detail = error.localizedDescription
                    if command.action.hasPrefix("record") {
                        detail += "; microphoneSource=\(model.recorder.microphoneSource); syntheticMicrophone=\(model.recorder.usesSyntheticMicrophone)"
                    }
                }
                let expectedError = command.expectError ?? false
                var passed = expectedError ? failed != nil : failed == nil
                if let contains = command.expectContains { passed = passed && detail.localizedCaseInsensitiveContains(contains) }
                if let count = command.expectCount { passed = passed && model.meetings.count == count }
                results.append(E2EResult(action: command.action, passed: passed, detail: detail, meetingCount: model.meetings.count, segmentCount: model.selected?.segments.count ?? 0))
                try JSONEncoder().encode(results).write(to: resultURL, options: .atomic)
                fputs("E2E finished \(command.action): \(passed)\n", stderr)
                if !passed { break }
            }
            if !terminateAfterResults { try await Task.sleep(nanoseconds: 300_000_000) }
            if terminateAfterResults { quitPhase("capturing screenshot") }
            try screenshot(to: resultURL.deletingPathExtension().appendingPathExtension("png"))
            if terminateAfterResults { quitPhase("screenshot captured") }
        } catch {
            let source = terminateAfterResults ? "; microphoneSource=\(model.recorder.microphoneSource); syntheticMicrophone=\(model.recorder.usesSyntheticMicrophone)" : ""
            results.append(E2EResult(action: "harness", passed: false, detail: error.localizedDescription + source, meetingCount: model.meetings.count, segmentCount: 0))
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if terminateAfterResults { quitPhase("writing preliminary results") }
            try encoder.encode(results).write(to: resultURL, options: .atomic)
            if terminateAfterResults { quitPhase("preliminary results written") }
        } catch {
            results.append(E2EResult(action: "harness", passed: false, detail: "Could not write E2E results: \(error.localizedDescription); microphoneSource=\(model.recorder.microphoneSource); syntheticMicrophone=\(model.recorder.usesSyntheticMicrophone)", meetingCount: model.meetings.count, segmentCount: 0))
            if !terminateAfterResults { fputs("Could not write E2E results\n", stderr); exit(2) }
        }
        if terminateAfterResults {
            shutdownResults = results
            shutdownURL = resultURL
            do { try await terminateCaptureScenario() }
            catch { await failQuitScenario(error) }
            return
        }
        exit(results.allSatisfy(\.passed) && !results.isEmpty ? 0 : 1)
    }
    private func execute(_ command: E2ECommand) async throws -> String {
        func require(_ value: String?, _ name: String) throws -> String {
            guard let value, !value.isEmpty else { throw AppError("Missing \(name)") }; return value
        }
        switch command.action {
        case "verify":
            try await model.verify(); return "\(model.trust.state): \(model.trust.detail)"
        case "configureMock":
            try await model.configure(endpoint: model.settings.endpointURL, key: command.value ?? "")
            return model.trust.detail
        case "importAudio":
            try await model.importAudio(URL(fileURLWithPath: require(command.path, "path")), title: command.value ?? "E2E planning meeting")
            guard let meeting = model.selected, !meeting.segments.isEmpty else { throw AppError("No transcription segments") }
            return meeting.segments.map(\.text).joined(separator: "\n")
        case "notes":
            model.setNotes(try require(command.value, "value")); return model.selected?.scratchNotes ?? ""
        case "viewNotes":
            model.detailTab = "Notes"
            return model.selected?.summary ?? ""
        case "showScreen":
            switch try require(command.value, "value") {
            case "home": model.screen = .home
            case "chat": model.screen = .chat
            case "meeting": model.screen = .meeting
            case let other: throw AppError("Unknown screen \(other)")
            }
            return "screen=\(command.value ?? "")"
        case "nativePresentation":
            await Task.yield()
            guard let validate = model.validatePresentation else {
                throw AppError("Missing native Muesli presentation validation")
            }
            return try validate()
        case "nativeSummary":
            guard let controller = MuesliController.current,
                  let meeting = controller.appState.selectedMeeting else {
                throw AppError("Missing actual native selected meeting")
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                controller.resummarize(meeting: meeting) { result in
                    continuation.resume(with: result)
                }
            }
            try model.refresh()
            guard let summary = model.selected?.summary, !summary.isEmpty else {
                throw AppError("Native summary did not persist a secure meeting summary")
            }
            return summary
        case "nativeSyncPrivacy":
            let store = DictationStore(databaseURL: model.root.appendingPathComponent("muesli.db"))
            let mappings = try store.hushMeetingMappings()
            guard !model.meetings.isEmpty else { throw AppError("Sync privacy requires saved private meetings") }
            for meeting in model.meetings {
                guard let id = mappings[meeting.id] else { throw AppError("Private meeting has no native mapping") }
                // Genuine native edits mark rows dirty; exclusion must not depend on that flag.
                try store.updateMeetingTitle(id: id, title: meeting.title)
                try store.updateMeetingNotes(id: id, formattedNotes: meeting.summary)
            }
            guard try store.textRecordsNeedingSync().isEmpty,
                  try store.textRecordsForSyncMigration(kind: .meeting).isEmpty,
                  try store.textRecordNamesRequiringAccountVerification().isEmpty,
                  try !store.hasTextRecordsNeedingSync() else {
                throw AppError("Private meeting content entered the outbound cloud sync selection")
            }
            try model.refresh()
            return "Private meetings excluded from outbound sync after native edits"
        case "summarize":
            if let template = command.value {
                if ["General", "1:1", "Sales", "Standup"].contains(template) {
                    model.settings.template = template
                } else {
                    model.settings.template = "Custom"
                    model.settings.customTemplate = template
                }
            }
            try await model.summarize()
            guard let meeting = model.selected, !meeting.summary.isEmpty, !meeting.embeddings.isEmpty else { throw AppError("Summary or embeddings missing") }
            return meeting.summary
        case "nativeShortcut":
            guard let shortcut = model.nativeShortcut else {
                throw AppError("Missing native Muesli keyboard shortcut action")
            }
            return try await shortcut(require(command.value, "value"))
        case "nativeSearch":
            guard let search = model.nativeSearch else {
                throw AppError("Missing native Muesli search action")
            }
            return try await search(require(command.value, "value"))
        case "nativeLocalTranscription":
            guard let transcribe = model.nativeLocalTranscription else {
                throw AppError("Missing native Muesli local transcription action")
            }
            let path = try require(command.path, "path")
            let backend = try require(command.value, "value")
            guard backend == "tiny.en" else {
                throw AppError("Local transcription verification requires the actual tiny.en backend")
            }
            return try await transcribe(URL(fileURLWithPath: path), backend)
        case "search":
            let found = try await model.search(try require(command.value, "value"))
            return found.map(\.title).joined(separator: "\n")
        case "ask":
            try await model.ask(try require(command.value, "value")); return model.answer
        case "backup":
            try model.backup(to: URL(fileURLWithPath: require(command.path, "path")), phrase: require(command.phrase, "phrase")); return "Backup saved"
        case "restore":
            try model.restore(from: URL(fileURLWithPath: require(command.path, "path")), phrase: require(command.phrase, "phrase")); return "Backup restored"
        case "delete":
            try model.deleteSelected(); return "Deleted"
        case "snapshot":
            try model.refresh()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(model.meetings), as: UTF8.self)
        case "login":
            try await model.login(try require(command.value, "value")); return "Signed in; quota loaded"
        case "quota":
            let quota = try await model.client.quota(); model.quotaValue = quota
            return "stake=\(quota.stakedYocto) credits=\(quota.creditsUsd) used=\(quota.usedUsd)"
        case "stake":
            try await model.stake(try require(command.value, "value"))
            return "stake=\(model.quotaValue?.stakedYocto ?? "") credits=\(model.quotaValue?.creditsUsd ?? 0)"
        case "rejectedModel":
            let previous = model.settings.model
            defer { model.settings.model = previous }
            model.settings.model = command.value ?? "gpt-4o"
            try await model.summarize()
            return model.selected?.summary ?? ""
        case "rejectedEndpoint":
            let previousEndpoint = model.settings.endpointURL
            do {
                try await model.configure(endpoint: command.value ?? "http://example.com", key: "mock-candidate")
                return "Unexpected endpoint acceptance"
            } catch {
                guard model.settings.endpointURL == previousEndpoint else { throw AppError("Failed configuration mutated current endpoint") }
                throw error
            }
        case "pendingQueue":
            let batches = try model.vault.pendingChunks()
            return "pending=\(batches.reduce(0) { $0 + $1.chunks.count })"
        case "concurrentSummaryEdit":
            let task = Task { @MainActor in try await model.summarize() }
            try await Task.sleep(nanoseconds: 80_000_000)
            model.setNotes(command.value ?? "Edited during summary. Private scratch note.")
            try await task.value
            return "Unexpected stale summary acceptance"
        case "concurrentRestore":
            let path = try require(command.path, "path")
            let phrase = try require(command.phrase, "phrase")
            let audio = try require(command.value, "audio fixture")
            let task = Task { @MainActor in try await model.importAudio(URL(fileURLWithPath: audio), title: "Concurrent restore meeting") }
            try await Task.sleep(nanoseconds: 80_000_000)
            var restoreError: Error?
            do { try model.restore(from: URL(fileURLWithPath: path), phrase: phrase) } catch { restoreError = error }
            try await task.value
            if let restoreError { throw restoreError }
            return "Unexpected concurrent restore acceptance"
        case "retryQueue":
            try await model.flushQueue(); return "Queued audio retried"
        case "captureAuthorization":
            let status: String
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: status = "authorized"
            case .notDetermined: status = "notDetermined — OS microphone permission has not been granted; a recording request may await the macOS dialog"
            case .denied: status = "denied — enable Microphone access in macOS Privacy & Security"
            case .restricted: status = "restricted — macOS policy prevents microphone access"
            @unknown default: status = "unknown"
            }
            let input: String
            do { input = "defaultInputDevice=\(try model.recorder.microphoneInputDevice())" }
            catch { input = "defaultInputDevice=unavailable — \(error.localizedDescription)" }
            return "microphone=\(status); \(input); microphoneSource=\(model.recorder.microphoneSource); syntheticMicrophone=\(model.recorder.usesSyntheticMicrophone); systemAudio=requires real Core Audio tap startup (no public authorization preflight)"
        case "record", "recordBusy", "recordQuit", "recordQuitWriteFailure":
            return try await capture(command)
        case "recordPause":
            return try await capturePause(command)
        case "nativeDiscard":
            return try await captureNativeDiscard(command)
        case "recordDeviceFailure", "recordCleanupFailure":
            return try await captureDeviceFailure(command)
        case "recordOverlappingStop":
            return try await captureOverlappingStop(command)
        case "recordStartFailure":
            return try await captureStartFailure()
        case "playbackLifecycle":
            let startedAt = ProcessInfo.processInfo.systemUptime
            let player = try playback(command)
            try await Task.sleep(nanoseconds: 150_000_000)
            guard player.isRunning else {
                try stopPlayback(player)
                throw AppError("Owned playback exited before the early-stop scenario")
            }
            try stopPlayback(player)
            guard player.terminationReason == .uncaughtSignal,
                  [SIGTERM, SIGKILL].contains(player.terminationStatus) else {
                throw AppError("Owned playback did not exit through the requested early-stop signal")
            }
            return try captureJSON(["playbackReaped": true, "stoppedEarly": true,
                                    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - startedAt,
                                    "terminationSignal": player.terminationStatus])
        case "recordUnavailableInput":
            var inputError: Error?
            do { _ = try model.recorder.microphoneInputDevice() } catch { inputError = error }
            guard inputError?.localizedDescription.contains("No microphone input device is available") == true else {
                throw AppError("Missing-input scenario requires a genuinely absent default microphone")
            }
            model.toggleRecording()
            try await waitFor("actionable missing-microphone UI error") { !model.busy && model.error != nil }
            guard !model.recording, let message = model.error, message.contains("No microphone input device is available") else {
                throw AppError("Missing input did not leave recording stopped with its actionable error")
            }
            throw AppError(message)
        default: throw AppError("Unknown E2E action \(command.action)")
        }
    }
    private func waitFor(_ description: String, condition: () throws -> Bool) async throws {
        for _ in 0..<200 {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AppError("Timed out waiting for \(description)")
    }

    private func playback(_ command: E2ECommand) throws -> Process {
        guard let path = command.path, !path.isEmpty else { throw AppError("Missing playback fixture path") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let duration = Double(file.length) / file.fileFormat.sampleRate
        guard duration.isFinite, abs(duration - 4) < 0.01 else {
            throw AppError("Real capture requires a four-second WAV playback fixture")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [path]
        try process.run()
        return process
    }

    private func stopPlayback(_ process: Process) throws {
        if process.isRunning { process.terminate() }
        let terminateDeadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < terminateDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            let status = kill(process.processIdentifier, SIGKILL)
            guard status == 0 || errno == ESRCH else { throw AppError("Could not kill owned afplay (\(errno))") }
            let killDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard !process.isRunning else { throw AppError("Owned afplay did not exit after bounded terminate/SIGKILL") }
        process.waitUntilExit()
    }

    private func requireCompletedPlayback(_ process: Process, playbackStartedAt: Double, captureStartedAt: Double) throws {
        let running = process.isRunning
        let status = running ? nil : Optional(process.terminationStatus)
        guard running || status != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var detail: [String: Any] = [
            "isRunning": running,
            "playbackElapsedSeconds": now - playbackStartedAt,
            "captureElapsedSeconds": now - captureStartedAt,
            "recording": model.recording,
            "microphoneSource": model.recorder.microphoneSource, "syntheticMicrophone": model.recorder.usesSyntheticMicrophone,
            "systemCaptureFormat": model.recorder.lastSystemCaptureFormat as Any? ?? NSNull(),
            "modelError": model.error as Any? ?? NSNull()
        ]
        if let status {
            detail["terminationStatus"] = status
            detail["terminationReason"] = process.terminationReason == .exit ? "exit" : "uncaughtSignal"
        }
        throw AppError("Owned afplay did not complete four-second playback successfully: \(try captureJSON(detail))")
    }

    private func awaitCompletedPlayback(_ process: Process, playbackStartedAt: Double, captureStartedAt: Double) async throws {
        let deadline = playbackStartedAt + 6
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try requireCompletedPlayback(process, playbackStartedAt: playbackStartedAt, captureStartedAt: captureStartedAt)
    }

    private func capture(_ command: E2ECommand) async throws -> String {
        if command.action == "recordQuitWriteFailure" { _ = try isolatedVaultPermissions() }
        try await model.startRecording()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var player: Process?
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let playbackStartedAt = ProcessInfo.processInfo.systemUptime
            let ownedPlayer = try playback(command)
            player = ownedPlayer
            if ["recordQuit", "recordQuitWriteFailure"].contains(command.action) {
                // afplay launch precedes audible tap PCM; keep startup-latency
                // headroom for the two-second tail while the four-second clip is live.
                try await Task.sleep(nanoseconds: 2_500_000_000)
                guard let meeting = model.selected else { throw AppError("Missing live capture meeting") }
                quitPlayer = ownedPlayer
                quitMeetingID = meeting.id
                quitStartedAt = startedAt
                quitWriteDenial = command.action == "recordQuitWriteFailure"
                try validateBufferedQuit()
                terminationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: NSApplication.shared, queue: .main
                ) { [self] _ in
                    MainActor.assumeIsolated { self.finalizeShutdownEvidence() }
                }
                terminateAfterResults = true
                return try quitEvidence(shutdownCompleted: false, playbackReaped: false)
            }
            try await awaitCompletedPlayback(ownedPlayer, playbackStartedAt: playbackStartedAt, captureStartedAt: startedAt)
            if command.action == "recordBusy" {
                guard let title = model.selected?.title, !title.isEmpty else { throw AppError("Busy-stop Ask requires the real saved meeting title") }
                model.run { try await self.model.ask(title) }
                guard model.busy else { throw AppError("Inference action did not enter busy state") }
                guard let controller = MuesliController.current else {
                    throw AppError("Missing actual native controller for busy-stop action")
                }
                controller.stopMeetingRecording()
                try await waitFor("UI stop while inference is busy") { !model.recording }
                guard model.busy else { throw AppError("Inference completed before the UI stop was observed") }
                try await waitFor("busy inference and real capture tail completion") {
                    guard !model.busy, model.recorder.lastCapturedDurations.microphone >= 4.5 else { return false }
                    return try model.vault.pendingChunks().isEmpty
                }
                if let error = model.error { throw AppError(error) }
                guard !model.answer.isEmpty else { throw AppError("Busy-stop Ask did not return a successful answer") }
            } else {
                try await model.stopRecording()
            }
            try stopPlayback(ownedPlayer)
            return try captureEvidence()
        } catch {
            let original = error
            try? await model.stopRecording()
            if let player {
                do { try stopPlayback(player) }
                catch { throw AppError("\(original.localizedDescription); playback cleanup failed: \(error.localizedDescription)") }
            }
            throw original
        }
    }
    private func captureNativeDiscard(_ command: E2ECommand) async throws -> String {
        guard let discard = model.nativeDiscardRecording else {
            throw AppError("Missing actual native confirmed-discard action")
        }
        let originalMeetings = try model.vault.meetings()
        guard let retained = originalMeetings.last else {
            throw AppError("Native discard coverage requires an already saved unrelated meeting")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalSnapshot = try encoder.encode(originalMeetings)
        try await model.startRecording()
        guard let captureID = model.recordingMeetingID, captureID != retained.id else {
            try? await model.stopRecording()
            throw AppError("Native discard did not create a distinct capture identity")
        }
        var player: Process?
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let ownedPlayer = try playback(command)
            player = ownedPlayer
            try await Task.sleep(nanoseconds: 2_500_000_000)
            guard model.recording, ownedPlayer.isRunning else {
                throw AppError("Native discard requires live known playback and capture")
            }
            model.selectedID = retained.id
            model.screen = .meeting
            guard model.selectedID != captureID, model.recordingMeetingID == captureID else {
                throw AppError("Selecting an unrelated meeting changed the active capture identity")
            }
            try await discard()
            try stopPlayback(ownedPlayer)
            player = nil
            try model.refresh()
            let persisted = try model.vault.meetings()
            guard !model.recording, !model.recordingPaused, model.recordingMeetingID == nil,
                  model.selectedID == retained.id,
                  !persisted.contains(where: { $0.id == captureID }),
                  try encoder.encode(persisted) == originalSnapshot,
                  !(try model.vault.pendingChunks()).contains(where: { $0.meetingID == captureID }) else {
                throw AppError("Native discard deleted the selected unrelated meeting or failed to remove only its stopped capture")
            }
            let durations = model.recorder.lastCapturedDurations
            guard durations.microphone >= 2, durations.system >= 2 else {
                throw AppError("Native discard did not stop a genuinely active two-channel capture")
            }
            return try captureJSON([
                "discardedRecordingMeetingID": captureID.uuidString,
                "retainedSelectedMeetingID": retained.id.uuidString,
                "preexistingMeetingsPreservedExactly": true, "onlyRecordingMeetingDeleted": true,
                "microphonePCMSeconds": durations.microphone, "systemPCMSeconds": durations.system,
                "recordingStopped": true, "discardedEncryptedQueueRemoved": true,
                "microphoneSource": model.recorder.microphoneSource,
                "syntheticMicrophone": model.recorder.usesSyntheticMicrophone
            ])
        } catch {
            let original = error
            try? await model.stopRecording()
            if let player {
                do { try stopPlayback(player) }
                catch { throw AppError("\(original.localizedDescription); playback cleanup failed: \(error.localizedDescription)") }
            }
            throw original
        }
    }
    private func capturePause(_ command: E2ECommand) async throws -> String {
        guard model.recorder.usesSyntheticMicrophone else {
            throw AppError("Pause coverage requires the explicit synthetic microphone verification source")
        }
        try await model.startRecording()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var player: Process?
        func playToCompletion() async throws {
            let playbackStartedAt = ProcessInfo.processInfo.systemUptime
            let owned = try playback(command)
            player = owned
            try await awaitCompletedPlayback(owned, playbackStartedAt: playbackStartedAt, captureStartedAt: startedAt)
            try stopPlayback(owned)
            player = nil
        }
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await playToCompletion()
            model.toggleRecordingPause()
            guard model.recording, model.recordingPaused,
                  let pauseStart = model.recorder.captureElapsedTime else {
                throw AppError("Native pause action did not pause the live capture")
            }
            let beforePause = model.recorder.capturedDurations
            guard beforePause.microphone >= 4.5, beforePause.system >= 4 else {
                throw AppError("Pause scenario did not first capture both actual source pipelines")
            }
            // Keep known system playback and continuous synthetic microphone input
            // running while paused; no borrowed PCM may enter either bounded pipe.
            try await playToCompletion()
            let afterPause = model.recorder.capturedDurations
            guard afterPause.microphone == beforePause.microphone,
                  afterPause.system == beforePause.system,
                  let resumeStart = model.recorder.captureElapsedTime,
                  resumeStart - pauseStart >= 4 else {
                throw AppError("Paused capture consumed PCM or did not exercise a four-second gap")
            }
            model.toggleRecordingPause()
            guard model.recording, !model.recordingPaused else {
                throw AppError("Native resume action did not resume the live capture")
            }
            try await playToCompletion()
            try await model.stopRecording()
            guard !model.recording, !model.recordingPaused,
                  try model.vault.pendingChunks().isEmpty,
                  let meeting = model.selected else {
                throw AppError("Paused recording did not stop and drain its encrypted queue")
            }
            let durations = model.recorder.lastCapturedDurations
            guard durations.microphone - afterPause.microphone >= 3.8,
                  durations.system - afterPause.system >= 4 else {
                throw AppError("Resumed recording did not make new PCM capture progress")
            }
            for segment in meeting.segments {
                guard segment.end <= pauseStart + 0.1 || segment.start >= resumeStart - 0.1 else {
                    throw AppError("Captured chunk spanned the paused sample-clock gap")
                }
            }
            for channel in [AudioChannel.me, .them] {
                let before = meeting.segments.filter { $0.channel == channel && $0.end <= pauseStart + 0.1 }
                let after = meeting.segments.filter { $0.channel == channel && $0.start >= resumeStart - 0.1 }
                guard unionCoverage(before.map { ($0.start, $0.end) }) >= 3.8,
                      unionCoverage(after.map { ($0.start, $0.end) }) >= 3.8 else {
                    throw AppError("Pause/resume dropped the pre-pause tail or resumed channel audio")
                }
            }
            let capture = try captureEvidence(minimumMicrophone: 8, minimumSystem: 8, maximumPCM: 15, minimumTail: 8)
            return try captureJSON([
                "capture": try JSONSerialization.jsonObject(with: Data(capture.utf8)),
                "pauseStart": pauseStart, "resumeStart": resumeStart,
                "pausedMicrophonePCMSeconds": afterPause.microphone - beforePause.microphone,
                "pausedSystemPCMSeconds": afterPause.system - beforePause.system,
                "resumedMicrophonePCMSeconds": durations.microphone - afterPause.microphone,
                "resumedSystemPCMSeconds": durations.system - afterPause.system,
                "sampleClockGapPreserved": true, "recordingStopped": true, "encryptedQueueDrained": true
            ])
        } catch {
            let original = error
            try? await model.stopRecording()
            if let player {
                do { try stopPlayback(player) }
                catch { throw AppError("\(original.localizedDescription); playback cleanup failed: \(error.localizedDescription)") }
            }
            throw original
        }
    }
    private func captureOverlappingStop(_ command: E2ECommand) async throws -> String {
        try await model.startRecording()
        var player: Process?
        var stopTasks: [Task<Void, Error>] = []
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let firstPlayer = try playback(command)
            player = firstPlayer
            // Collect a two-second live tail despite afplay startup latency,
            // without extending the fixture or lowering retained-coverage minima.
            try await Task.sleep(nanoseconds: 2_500_000_000)
            guard firstPlayer.isRunning, model.recording else { throw AppError("Overlapping stop requires live known playback and actual recording") }
            var entered: Set<Int> = []
            var completed: [Int] = []
            var restartClaimed = false
            var firstEvidence: String?
            var firstMeeting: Meeting?
            var recoveryID: UUID?
            var recoveryStartedAt: Double?
            @MainActor func stopAndRestart(_ caller: Int) async throws {
                entered.insert(caller)
                try await model.stopRecording()
                completed.append(caller)
                guard entered.count == 2 else { throw AppError("Stop callers did not actually overlap before first completion") }
                if !restartClaimed {
                    restartClaimed = true
                    firstEvidence = try captureEvidence(minimumMicrophone: 2, minimumSystem: 2, maximumPCM: 5, minimumTail: 2)
                    firstMeeting = model.selected
                    // Start immediately from the first completed real stop, without
                    // awaiting the other caller or creating a new model/process.
                    try await model.startRecording()
                    recoveryStartedAt = ProcessInfo.processInfo.systemUptime
                    recoveryID = model.selectedID
                }
            }
            let first = Task { @MainActor in try await stopAndRestart(1) }
            let second = Task { @MainActor in try await stopAndRestart(2) }
            stopTasks = [first, second]
            try await first.value
            try await second.value
            guard completed.count == 2, let firstEvidence, let firstMeeting,
                  let recoveryID, let recoveryStartedAt, recoveryID != firstMeeting.id, model.recording else {
                throw AppError("Overlapping stop did not permit an immediate distinct same-instance recording")
            }
            try stopPlayback(firstPlayer)
            player = nil
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let playbackStartedAt = ProcessInfo.processInfo.systemUptime
            let recoveryPlayer = try playback(command)
            player = recoveryPlayer
            try await awaitCompletedPlayback(recoveryPlayer, playbackStartedAt: playbackStartedAt, captureStartedAt: recoveryStartedAt)
            try await model.stopRecording()
            try stopPlayback(recoveryPlayer)
            let recovery = try captureEvidence()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let persistedFirst = try model.vault.meetings().first(where: { $0.id == firstMeeting.id }),
                  try encoder.encode(persistedFirst) == encoder.encode(firstMeeting) else {
                throw AppError("Immediate restart changed the first recording's persisted transcript or identity")
            }
            return try captureJSON([
                "processID": getpid(), "overlappingCallerCount": entered.count,
                "microphoneSource": model.recorder.microphoneSource, "syntheticMicrophone": model.recorder.usesSyntheticMicrophone,
                "completionOrder": completed, "restartedAfterFirstCompletion": true,
                "firstCapture": try JSONSerialization.jsonObject(with: Data(firstEvidence.utf8)),
                "recoveryCapture": try JSONSerialization.jsonObject(with: Data(recovery.utf8))
            ])
        } catch {
            let original = error
            for task in stopTasks { _ = try? await task.value }
            try? await model.stopRecording()
            if let player {
                do { try stopPlayback(player) }
                catch { throw AppError("\(original.localizedDescription); playback cleanup failed: \(error.localizedDescription)") }
            }
            throw original
        }
    }

    private func quitPhase(_ value: String) {
        fputs("E2E quit phase: \(value); owned pid=\(getpid()); capture elapsed=\(ProcessInfo.processInfo.systemUptime - quitStartedAt); microphoneSource=\(model.recorder.microphoneSource); syntheticMicrophone=\(model.recorder.usesSyntheticMicrophone)\n", stderr)
        fflush(stderr)
    }

    private func validateBufferedQuit() throws {
        guard model.recording, let player = quitPlayer, player.isRunning, let id = quitMeetingID,
              let meeting = try model.vault.meetings().first(where: { $0.id == id }),
              !meeting.segments.contains(where: { $0.channel == .them }),
              !(try model.vault.pendingChunks()).contains(where: {
                  $0.meetingID == id && $0.chunks.contains(where: { $0.channel == .them })
              }) else {
            throw AppError("Live-quit precondition expired: playback must still run and this session must have no stored/transcribed them chunk")
        }
    }

    private func quitEvidence(shutdownCompleted: Bool, playbackReaped: Bool) throws -> String {
        guard let id = quitMeetingID else { throw AppError("Missing quit session identity") }
        var values: [String: Any] = [
            "meetingID": id.uuidString, "liveBufferedAtQuitRequest": quitBufferedAtRequest,
            "minimumTailSeconds": 2,
            "shutdownCompleted": shutdownCompleted, "playbackReaped": playbackReaped,
            "quitRefusedOnWriteDenial": quitRefused,
            "memoryTailRecoveredToEncryptedQueue": memoryTailRecovered,
            "microphoneSource": model.recorder.microphoneSource, "syntheticMicrophone": model.recorder.usesSyntheticMicrophone,
            "systemCaptureFormat": model.recorder.lastSystemCaptureFormat as Any? ?? NSNull(),
            "externalServices": "EXPLICIT LOCAL MOCKS"
        ]
        if quitBufferedAtRequest { values["themChunksBeforeQuit"] = 0 }
        if let elapsed = quitRequestElapsed { values["elapsedAtQuitRequestSeconds"] = elapsed }
        else { values["elapsedAtPreTerminationCheckSeconds"] = ProcessInfo.processInfo.systemUptime - quitStartedAt }
        if shutdownCompleted || quitRefused {
            values["microphonePCMSeconds"] = model.recorder.lastCapturedDurations.microphone
            values["systemPCMSeconds"] = model.recorder.lastCapturedDurations.system
        }
        return try captureJSON(values)
    }

    private func saveShutdownResults() throws {
        guard let url = shutdownURL else { throw AppError("Missing shutdown evidence destination") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(shutdownResults).write(to: url, options: .atomic)
    }

    private func updateQuitResult(shutdownCompleted: Bool, playbackReaped: Bool) throws {
        guard let index = shutdownResults.lastIndex(where: { ["recordQuit", "recordQuitWriteFailure"].contains($0.action) }) else {
            throw AppError("Missing quit result row")
        }
        let row = shutdownResults[index]
        shutdownResults[index] = E2EResult(action: row.action, passed: row.passed,
            detail: try quitEvidence(shutdownCompleted: shutdownCompleted, playbackReaped: playbackReaped),
            meetingCount: model.meetings.count, segmentCount: model.selected?.segments.count ?? 0)
        try saveShutdownResults()
    }

    private func isolatedVaultPermissions() throws -> NSNumber {
        guard options.e2e, model.testMode, options.root?.standardizedFileURL == model.root.standardizedFileURL,
              model.root.standardizedFileURL.pathComponents.contains(".e2e") else {
            throw AppError("Write denial is restricted to the explicitly isolated .e2e vault")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: model.root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber else { throw AppError("Cannot safely deny isolated vault writes") }
        return permissions
    }

    private func restoreDeniedVault() throws {
        if let permissions = deniedVaultPermissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: model.root.path)
            deniedVaultPermissions = nil
        }
    }

    private func requestNativeTermination(_ description: String, liveBuffer: Bool = false) async throws {
        quitPhase("scheduling native run-loop termination: \(description)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            RunLoop.main.perform { [self] in
                MainActor.assumeIsolated {
                    quitPhase("native run-loop termination event: \(description)")
                    do {
                        if liveBuffer {
                            try validateBufferedQuit()
                            if quitWriteDenial {
                                deniedVaultPermissions = try isolatedVaultPermissions()
                                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: model.root.path)
                            }
                            try validateBufferedQuit()
                            quitBufferedAtRequest = true
                            quitRequestElapsed = ProcessInfo.processInfo.systemUptime - quitStartedAt
                        }
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    // A native run-loop event, not an active Swift main-actor job,
                    // lets terminateLater's nested AppKit loop run the delegate Task.
                    quitPhase("requesting actual NSApplication termination: \(description)")
                    NSApplication.shared.terminate(nil)
                    quitPhase("NSApplication.terminate returned: \(description)")
                    continuation.resume()
                }
            }
        }
    }

    private func terminateCaptureScenario() async throws {
        quitPhase("entering termination scenario")
        guard shutdownResults.allSatisfy(\.passed) else { throw AppError("Quit scenario evidence failed before termination") }
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else {
            throw AppError("Missing actual application termination delegate")
        }
        defer { delegate.e2eTerminationReply = nil }
        if quitWriteDenial {
            delegate.e2eTerminationReply = { [weak self] allowed in
                if !allowed { self?.quitRefused = true }
            }
        }
        try await requestNativeTermination("first request", liveBuffer: true)
        if !quitWriteDenial { return }
        try await waitFor("actual AppDelegate refusal of live-tail write denial") {
            quitRefused && !model.recording && model.error?.contains("storage I/O failed") == true
        }
        quitPhase("actual AppDelegate refusal observed")
        guard model.error?.contains("storage I/O failed") == true, let id = quitMeetingID,
              !(try model.vault.pendingChunks()).contains(where: {
                  $0.meetingID == id && $0.chunks.contains(where: { $0.channel == .them })
              }),
              !(try model.vault.meetings()).contains(where: {
                  $0.id == id && $0.segments.contains(where: { $0.channel == .them })
              }) else { throw AppError("Quit refusal did not preserve a genuinely memory-only failed them tail") }
        if let player = quitPlayer { try stopPlayback(player) }
        try restoreDeniedVault()
        quitPhase("retrying memory-only tail after restoring vault permissions")
        do { try await model.stopRecording() }
        catch {
            guard error.localizedDescription.contains("HTTP 503") else { throw error }
        }
        let stored = try model.vault.pendingChunks().first(where: { $0.meetingID == id })
        let systemWindows = (stored?.chunks ?? []).lazy.filter { $0.channel == .them }
            .map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        let storedCoverage = unionCoverage(systemWindows)
        guard storedCoverage >= 2 else {
            throw AppError("Restored write access did not persist required them tail union coverage: coverage=\(storedCoverage)s, deficit=\(max(0, 2 - storedCoverage))s, windows=\(systemWindows)")
        }
        memoryTailRecovered = true
        try updateQuitResult(shutdownCompleted: false, playbackReaped: true)
        try await requestNativeTermination("second request after durable tail recovery")
    }

    private func shutdownFailure(_ error: Error) {
        shutdownResults.append(E2EResult(action: "harness", passed: false, detail: "\(error.localizedDescription); microphoneSource=\(model.recorder.microphoneSource); syntheticMicrophone=\(model.recorder.usesSyntheticMicrophone)",
            meetingCount: model.meetings.count, segmentCount: model.selected?.segments.count ?? 0))
    }

    private func failQuitScenario(_ error: Error) async {
        shutdownFailure(error)
        do { try restoreDeniedVault() } catch { shutdownFailure(error) }
        if let player = quitPlayer {
            do { try stopPlayback(player) } catch { shutdownFailure(error) }
        }
        try? await model.stopRecording()
        do { try saveShutdownResults() } catch { fputs("Could not persist failed shutdown evidence: \(error.localizedDescription)\n", stderr) }
        do { try await requestNativeTermination("failed scenario with failure evidence persisted") }
        catch {
            shutdownFailure(error)
            try? saveShutdownResults()
        }
    }

    private func finalizeShutdownEvidence() {
        quitPhase("actual willTerminate notification observed")
        if let observer = terminationObserver { NotificationCenter.default.removeObserver(observer) }
        terminationObserver = nil
        var reaped = false
        do {
            try restoreDeniedVault()
            if let player = quitPlayer { try stopPlayback(player) }
            reaped = true
        } catch { shutdownFailure(error) }
        do { try updateQuitResult(shutdownCompleted: true, playbackReaped: reaped) }
        catch {
            shutdownFailure(error)
            try? saveShutdownResults()
            fputs("Could not finalize shutdown evidence: \(error.localizedDescription)\n", stderr)
        }
    }

    private func captureJSON(_ values: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
    }

    // Callers validate finite nonnegative windows and chronological order first.
    private func unionCoverage<S: Sequence>(_ windows: S) -> Double where S.Element == (Double, Double) {
        var coverage = 0.0
        var previousEnd = 0.0
        for (start, end) in windows {
            coverage += max(0, end - max(start, previousEnd))
            previousEnd = max(previousEnd, end)
        }
        return coverage
    }

    private func captureEvidence(minimumMicrophone: Double = 4.5, minimumSystem: Double = 4,
                                 maximumPCM: Double = 8, minimumTail: Double = 4) throws -> String {
        let durations = model.recorder.lastCapturedDurations
        guard durations.microphone.isFinite, durations.system.isFinite else {
            throw AppError("Invalid consumed PCM durations: microphone=\(durations.microphone), system=\(durations.system); source=\(model.recorder.microphoneSource)")
        }
        guard let meeting = model.selected else { throw AppError("Captured meeting is missing") }
        let segments = meeting.segments
        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && !$0.text.isEmpty }),
              zip(segments, segments.dropFirst()).allSatisfy({ $0.0.start <= $0.1.start }),
              Set(segments.map(\.chunkID)).count == segments.count else {
            throw AppError("Captured transcript timestamps are invalid, unordered, or duplicated")
        }
        let microphoneCoverage = unionCoverage(segments.lazy.filter { $0.channel == .me }.map { ($0.start, $0.end) })
        let systemCoverage = unionCoverage(segments.lazy.filter { $0.channel == .them }.map { ($0.start, $0.end) })
        let requiredMicrophoneCoverage = model.recorder.usesSyntheticMicrophone ? minimumTail : 0
        let pending = try model.vault.pendingChunks().reduce(0) { $0 + $1.chunks.count }
        let evidence: [String: Any] = [
            "meetingID": meeting.id.uuidString, "processID": getpid(), "microphonePCMSeconds": durations.microphone,
            "systemPCMSeconds": durations.system, "pending": pending,
            "microphoneSource": model.recorder.microphoneSource, "syntheticMicrophone": model.recorder.usesSyntheticMicrophone,
            "systemCaptureFormat": model.recorder.lastSystemCaptureFormat as Any? ?? NSNull(),
            "microphoneTranscriptCoverageSeconds": microphoneCoverage, "systemTranscriptCoverageSeconds": systemCoverage,
            "requiredMicrophoneTranscriptCoverageSeconds": requiredMicrophoneCoverage,
            "requiredSystemTranscriptCoverageSeconds": minimumTail,
            "microphoneTranscriptDeficitSeconds": max(0, requiredMicrophoneCoverage - microphoneCoverage),
            "systemTranscriptDeficitSeconds": max(0, minimumTail - systemCoverage),
            "microphoneSegments": segments.filter { $0.channel == .me }.map {
                ["channel": $0.channel.rawValue, "chunkID": $0.chunkID.uuidString,
                 "start": $0.start, "end": $0.end, "source": model.recorder.microphoneSource] as [String: Any]
            },
            "systemTranscriptWindows": segments.filter { $0.channel == .them }.map {
                ["channel": $0.channel.rawValue, "chunkID": $0.chunkID.uuidString,
                 "start": $0.start, "end": $0.end, "source": "Core Audio process tap"] as [String: Any]
            },
            "channelOrdering": microphoneCoverage > 0 ?
                (model.recorder.usesSyntheticMicrophone ? "synthetic E2E microphone and real system channel present; chronological order verified" :
                    "both real channels present; chronological order verified") :
                "AVAudioEngine microphone PCM verified; no audible microphone segment — environmental silence prevents both-channel proof",
            "externalServices": "EXPLICIT LOCAL MOCKS"
        ]
        guard (minimumMicrophone...maximumPCM).contains(durations.microphone),
              (minimumSystem...maximumPCM).contains(durations.system) else {
            throw AppError("Consumed PCM outside required bounds (\(minimumMicrophone)...\(maximumPCM) microphone, \(minimumSystem)...\(maximumPCM) system): \(try captureJSON(evidence))")
        }
        guard systemCoverage >= minimumTail else {
            throw AppError("Known playback retained system transcript union coverage below required \(minimumTail)s: \(try captureJSON(evidence))")
        }
        guard microphoneCoverage >= requiredMicrophoneCoverage else {
            throw AppError("Synthetic microphone retained transcript union coverage below required \(minimumTail)s: \(try captureJSON(evidence))")
        }
        guard pending == 0, !model.recording else {
            throw AppError("Capture did not stop and drain persisted audio: \(try captureJSON(evidence))")
        }
        return try captureJSON(evidence)
    }

    private func audioDevices() throws -> Set<AudioObjectID> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              Int(size) % MemoryLayout<AudioObjectID>.size == 0 else { throw AppError("Cannot enumerate Core Audio devices safely") }
        guard size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw AppError("Cannot read Core Audio device enumeration") }
        return Set(devices.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func destroyOwnAggregate(previous: Set<AudioObjectID>) throws -> AudioObjectID {
        guard let device = model.recorder.activeSystemCaptureDevice, device != kAudioObjectUnknown,
              !previous.contains(device) else {
            throw AppError("Cannot verify a newly creation-owned capture handle; no device was destroyed (model error: \(model.error ?? "none"))")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let readStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard readStatus == noErr, let composition = value?.takeRetainedValue() as? [String: Any] else {
            throw AppError("Cannot read creation-owned aggregate composition; no device was destroyed (device=\(device), Core Audio \(readStatus), bytes=\(size))")
        }
        guard composition[kAudioAggregateDeviceNameKey] as? String == "Hush Capture",
              (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.intValue == 1,
              let uid = composition[kAudioAggregateDeviceUIDKey] as? String, UUID(uuidString: uid) != nil,
              let taps = composition[kAudioAggregateDeviceTapListKey] as? [[String: Any]], taps.count == 1,
              let tapUID = taps[0][kAudioSubTapUIDKey] as? String, UUID(uuidString: tapUID) != nil,
              (composition[kAudioAggregateDeviceSubDeviceListKey] == nil ||
               (composition[kAudioAggregateDeviceSubDeviceListKey] as? [Any])?.isEmpty == true) else {
            let detail: String
            if JSONSerialization.isValidJSONObject(composition) { detail = try captureJSON(composition) }
            else { detail = String(describing: composition) }
            throw AppError("Creation-owned aggregate failed private/name/UUID/one-tap/no-physical-subdevice guards; no device was destroyed (device=\(device), Core Audio \(readStatus), composition=\(detail))")
        }
        let status = AudioHardwareDestroyAggregateDevice(device)
        guard status == noErr else { throw AppError("Destroying owned private capture aggregate failed (\(status), device=\(device))") }
        return device
    }

    private func captureDeviceFailure(_ command: E2ECommand) async throws -> String {
        let previous = try audioDevices()
        try await model.startRecording()
        let captureStartedAt = ProcessInfo.processInfo.systemUptime
        var ownedPlayer: Process?
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let playbackStartedAt = ProcessInfo.processInfo.systemUptime
            let player = try playback(command)
            ownedPlayer = player
            try await awaitCompletedPlayback(player, playbackStartedAt: playbackStartedAt, captureStartedAt: captureStartedAt)
            let device = try destroyOwnAggregate(previous: previous)
            if command.action == "recordDeviceFailure" {
                try await waitFor("real capture device health failure and tail drain") {
                    !model.recording && model.error != nil && model.recorder.lastCapturedDurations.microphone >= 4.5
                }
                guard model.error?.contains("no longer available") == true else {
                    throw AppError("Missing actionable real device-health failure: \(model.error ?? "none")")
                }
            }
            let message: String
            if command.action == "recordDeviceFailure" {
                guard let observedFailure = model.error else { throw AppError("Missing original health failure evidence") }
                message = observedFailure
                // The real health handler has already consumed its failure. An idle
                // subsequent stop must be safe, not artificially rethrow old errors.
                try await model.stopRecording()
            } else {
                var stopError: Error?
                do { try await model.stopRecording() } catch { stopError = error }
                guard let stopError else { throw AppError("Destroyed capture aggregate did not surface a cleanup failure") }
                message = stopError.localizedDescription
                guard message.contains("failed (Core Audio"),
                      ["Stopping system audio capture", "Releasing system audio callback", "Releasing capture device"].contains(where: { message.contains($0) }) else {
                    throw AppError("Immediate stop did not surface a genuine cleanup failure: \(message)")
                }
            }
            let evidence = try captureEvidence()
            try stopPlayback(player)
            return try captureJSON(["destroyedOwnPrivateAggregate": device, "failure": message,
                                    "microphoneSource": model.recorder.microphoneSource, "syntheticMicrophone": model.recorder.usesSyntheticMicrophone,
                                    "capture": try JSONSerialization.jsonObject(with: Data(evidence.utf8))])
        } catch {
            let original = error
            try? await model.stopRecording()
            if let ownedPlayer {
                do { try stopPlayback(ownedPlayer) }
                catch { throw AppError("\(original.localizedDescription); playback cleanup failed: \(error.localizedDescription)") }
            }
            throw original
        }
    }

    private func captureStartFailure() async throws -> String {
        let permissions = try isolatedVaultPermissions()
        let manager = FileManager.default
        let before = try model.vault.meetings()
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: model.root.path)
        var failure: Error?
        do { try await model.startRecording() } catch { failure = error }
        // Restore before every assertion or recovery, even when startup unexpectedly succeeds.
        do { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: model.root.path) }
        catch {
            try? await model.stopRecording()
            throw AppError("Could not restore isolated vault permissions: \(error.localizedDescription)")
        }
        if failure == nil { try await model.stopRecording(); throw AppError("Write denial did not reject recording startup") }
        guard let failure, failure.localizedDescription.contains("storage I/O failed"),
              !model.recording, try model.vault.meetings().map(\.id) == before.map(\.id),
              try model.vault.pendingChunks().isEmpty else {
            throw AppError("Failed real start did not preserve vault state: \(failure?.localizedDescription ?? "none")")
        }
        return "Real filesystem write denial blocked recording before device startup; original permissions restored; no meeting or recording state committed; microphoneSource=\(model.recorder.microphoneSource); syntheticMicrophone=\(model.recorder.usesSyntheticMicrophone): \(failure.localizedDescription)"
    }
    private func screenshot(to url: URL) throws {
        guard let validate = model.validatePresentation else {
            throw AppError("Missing native Muesli presentation validation")
        }
        let presentation = try validate()
        try Data(presentation.utf8)
            .write(to: url.deletingPathExtension().appendingPathExtension("presentation.json"), options: .atomic)
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil }), let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError("No visible app window for screenshot") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError("Screenshot encoding failed") }
        try png.write(to: url)
        // Record actual AppKit/bundle identity alongside the rendered content screenshot.
        let identity = [
            "windowTitle": window.title,
            "executableName": ProcessInfo.processInfo.processName,
            "bundleName": Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
            "bundleExecutable": Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? ""
        ]
        try JSONSerialization.data(withJSONObject: identity, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.deletingPathExtension().appendingPathExtension("identity.json"), options: .atomic)
    }
}
