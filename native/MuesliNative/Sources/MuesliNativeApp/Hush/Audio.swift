import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import AppKit

private enum CaptureError: LocalizedError {
    case message(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .coreAudio(let operation, let status):
            return "\(operation) failed (Core Audio \(status)). Check the selected audio device and System Settings → Privacy & Security → Screen & System Audio Recording."
        }
    }
}

/// Both live channels and imported files feed this exact sample-clock chunker.
/// WAV encoding happens in memory: capture never creates plaintext temporary files.
private final class SampleChunker {
    static let maximumBytes = 25_000_000
    static let maximumDuration = 30.0
    private let channel: AudioChannel
    private let rate: Double
    private let emit: (AudioChunk) -> Void
    private let windowSize: Int
    private let maximumFrames: Int
    private var window: [Float] = []
    private var windowStart = 0.0
    private var expectedTime: Double?
    private var pcm = Data()
    private var start = 0.0
    private var frames = 0
    private var silenceFrames = 0
    private var hasSignal = false

    init(channel: AudioChannel, rate: Double, emit: @escaping (AudioChunk) -> Void) throws {
        guard rate.isFinite, rate >= 1, rate <= 768_000, rate.rounded() == rate else {
            throw CaptureError.message("Unsupported audio sample rate: \(rate).")
        }
        self.channel = channel
        self.rate = rate
        self.emit = emit
        windowSize = max(1, Int(rate * 0.02))
        maximumFrames = min(Int(rate * Self.maximumDuration), (Self.maximumBytes - 44) / 2)
        window.reserveCapacity(windowSize)
        pcm.reserveCapacity(maximumFrames * 2)
    }

    func consume(_ samples: UnsafeBufferPointer<Float>, timestamp: Double) {
        // A hardware clock discontinuity must not collapse a gap into continuous audio.
        if let expectedTime, abs(expectedTime - timestamp) > 0.1 {
            finish()
        }
        for index in samples.indices {
            if window.isEmpty { windowStart = timestamp + Double(index) / rate }
            let sample = samples[index]
            window.append(sample.isFinite ? min(1, max(-1, sample)) : 0)
            if window.count == windowSize { processWindow() }
        }
        expectedTime = timestamp + Double(samples.count) / rate
    }

    func finish() {
        if !window.isEmpty { processWindow() }
        trimSilence()
        flush()
        expectedTime = nil
    }

    private func processWindow() {
        var energy: Double = 0
        for sample in window { energy += Double(sample) * Double(sample) }
        let audible = energy / Double(window.count) >= 0.000009 // RMS ≥ 0.003, about −50 dBFS.
        if !audible && frames == 0 {
            window.removeAll(keepingCapacity: true)
            return
        }
        for index in window.indices {
            if frames == 0 { start = windowStart + Double(index) / rate }
            var encoded = Int16((window[index] * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &encoded) { pcm.append(contentsOf: $0) }
            frames += 1
            hasSignal = hasSignal || audible
            silenceFrames = audible ? 0 : silenceFrames + 1
            if frames == maximumFrames { flush() }
        }
        window.removeAll(keepingCapacity: true)
        if Double(silenceFrames) / rate >= 0.6 {
            trimSilence()
            flush()
        }
    }

    private func trimSilence() {
        let remove = max(0, silenceFrames - Int(rate * 0.2))
        if remove > 0 {
            pcm.removeLast(remove * 2)
            frames -= remove
            silenceFrames -= remove
        }
    }

    private func flush() {
        guard frames > 0 else { return }
        if hasSignal {
            var wav = Data()
            wav.reserveCapacity(pcm.count + 44)
            func integer<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
            }
            wav.append(contentsOf: "RIFF".utf8)
            integer(UInt32(pcm.count + 36))
            wav.append(contentsOf: "WAVEfmt ".utf8)
            integer(UInt32(16))
            integer(UInt16(1)) // PCM
            integer(UInt16(1)) // mono
            integer(UInt32(rate))
            integer(UInt32(rate) * 2)
            integer(UInt16(2))
            integer(UInt16(16))
            wav.append(contentsOf: "data".utf8)
            integer(UInt32(pcm.count))
            wav.append(pcm)
            emit(AudioChunk(channel: channel, start: start, end: start + Double(frames) / rate,
                            data: wav, mimeType: "audio/wav"))
        }
        pcm.removeAll(keepingCapacity: true)
        frames = 0
        silenceFrames = 0
        hasSignal = false
    }
}

/// Bounded preallocated handoff: OS-owned callback buffers are borrowed only during
/// the callback, while chunking/encoding/user callbacks run off the audio thread.
private final class CapturePipe: @unchecked Sendable {
    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        var count = 0
        var timestamp = 0.0
        init(capacity: Int) { samples = .allocate(capacity: capacity) }
        deinit { samples.deallocate() }
    }
    private static let capacity = 16_384
    private let queue = DispatchQueue(label: "Hush.audio.chunks")
    private let lock = NSLock()
    private let slots = (0..<16).map { _ in Slot(capacity: CapturePipe.capacity) }
    private var readIndex = 0
    private var writeIndex = 0
    private var occupied = 0
    private var accepting = false
    private var paused = false
    private var firstError: Error?
    private let chunker: SampleChunker
    private let rate: Double
    // Written only on the chunking queue; finish returns its final snapshot.
    private var consumedFrames = 0
    private let failure: @Sendable (Error) -> Void
    private var source: DispatchSourceUserDataAdd!

    init(channel: AudioChannel, rate: Double, emit: @escaping @Sendable (AudioChunk) -> Void,
         failure: @escaping @Sendable (Error) -> Void) throws {
        chunker = try SampleChunker(channel: channel, rate: rate, emit: emit)
        self.rate = rate
        self.failure = failure
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }

    deinit { source.cancel() }

    func activate() {
        lock.lock()
        if firstError == nil { accepting = true }
        lock.unlock()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
        if value {
            // Close the current sample-clock window before resume can accept more PCM.
            // Pre-pause borrowed buffers still drain and synchronously persist their tail.
            queue.sync { drain(); chunker.finish() }
        }
    }

    var capturedDuration: Double { queue.sync { Double(consumedFrames) / rate } }

    func receive(_ list: UnsafePointer<AudioBufferList>, timestamp: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mNumberChannels > 0,
              first.mData != nil else { return } // No system playback is ordinary silence.
        let count = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard count > 0 else { return }
        guard count <= Self.capacity,
              buffers.allSatisfy({ $0.mData != nil && $0.mNumberChannels > 0 &&
                  Int($0.mDataByteSize) / (MemoryLayout<Float>.size * Int($0.mNumberChannels)) == count }) else {
            fail(CaptureError.message("Audio device supplied an unsupported or oversized audio buffer."))
            return
        }
        lock.lock()
        guard accepting, !paused else { lock.unlock(); return }
        guard occupied < slots.count else {
            lock.unlock()
            fail(CaptureError.message("Audio processing could not keep up; recording stopped rather than dropping audio."))
            return
        }
        let slot = slots[writeIndex]
        let totalChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        for frame in 0..<count {
            var sample: Float = 0
            for buffer in buffers {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                let channels = Int(buffer.mNumberChannels)
                for channel in 0..<channels { sample += data[frame * channels + channel] }
            }
            slot.samples[frame] = sample / Float(totalChannels)
        }
        slot.count = count
        slot.timestamp = timestamp
        writeIndex = (writeIndex + 1) % slots.count
        occupied += 1
        lock.unlock()
        source.add(data: 1)
    }

    func fail(_ error: Error) {
        lock.lock()
        let notify = firstError == nil
        if notify { firstError = error }
        accepting = false
        lock.unlock()
        if notify { failure(error) }
    }

    private func drain() {
        while true {
            lock.lock()
            guard occupied > 0 else { lock.unlock(); return }
            let slot = slots[readIndex]
            lock.unlock()
            chunker.consume(UnsafeBufferPointer(start: slot.samples, count: slot.count), timestamp: slot.timestamp)
            consumedFrames += slot.count
            lock.lock()
            readIndex = (readIndex + 1) % slots.count
            occupied -= 1
            lock.unlock()
        }
    }

    private func closeInput() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    func finish(deliver: Bool = true) async -> (error: Error?, duration: Double) {
        closeInput()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if deliver { drain(); chunker.finish() }
                source.cancel()
                lock.lock()
                let error = firstError
                lock.unlock()
                continuation.resume(returning: (error, Double(consumedFrames) / rate))
            }
        }
    }
}

/// Explicit E2E injection only: real-time PCM enters the same borrowed-buffer pipe
/// as AVAudioEngine. The repeating 20 ms dual tone is allocated and filled once.
private final class SyntheticMicrophone: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private let queue = DispatchQueue(label: "Hush.audio.synthetic-microphone")
    private let timer: DispatchSourceTimer
    private var stopped = false

    init(pipe: CapturePipe, epoch: Double) throws {
        let frames: AVAudioFrameCount = 320
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let samples = buffer.floatChannelData?[0] else {
            throw CaptureError.message("Could not allocate synthetic E2E microphone PCM.")
        }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let time = Double(frame) / Self.sampleRate
            samples[frame] = Float(0.12 * sin(2 * .pi * 700 * time) +
                                  0.12 * sin(2 * .pi * 1_100 * time))
        }
        timer = DispatchSource.makeTimerSource(queue: queue)
        // Capture the buffer, not this owner: no timer retention cycle, and no
        // owner deinit on the callback queue while stop synchronizes with it.
        timer.setEventHandler {
            let timestamp = AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime()) - epoch - 0.02
            pipe.receive(buffer.audioBufferList, timestamp: max(0, timestamp))
        }
        timer.schedule(deadline: .distantFuture)
        // Always resume, including failed-start paths, so cancellation is safe.
        timer.resume()
    }

    func start() {
        timer.schedule(deadline: .now() + .milliseconds(20),
                       repeating: .milliseconds(20), leeway: .milliseconds(1))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer.cancel()
        // An executing callback must finish copying before the pipe is drained.
        queue.sync {}
    }

    deinit { stop() }
}

@MainActor
final class AudioRecorder {
    private enum State { case idle, starting, recording, stopping }
    private var state = State.idle
    private var engine: AVAudioEngine?
    private var micTapInstalled = false
    private var syntheticMic: SyntheticMicrophone?
    private var processTap: AudioObjectID = kAudioObjectUnknown
    private var aggregate: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var micPipe: CapturePipe?
    private var systemPipe: CapturePipe?
    private var configurationObserver: NSObjectProtocol?
    private var healthTimer: DispatchSourceTimer?
    private var captureError: Error?
    private var stopTask: Task<Void, Error>?
    private var generation: UInt64 = 0
    private var captureEpoch: TimeInterval?
    /// Runtime failures stop resources immediately; report via onFailure or a later stop.
    var onFailure: (@Sendable (String) -> Void)?
    /// PCM time actually delivered to each chunker, including legitimate silence.
    private(set) var lastCapturedDurations = (microphone: 0.0, system: 0.0)
    /// Synthetic E2E only; read-only hardware format metadata, never PCM content.
    private(set) var lastSystemCaptureFormat: String?
    let usesSyntheticMicrophone: Bool
    var microphoneSource: String { usesSyntheticMicrophone ? "SYNTHETIC E2E PCM" : "AVAudioEngine" }

    init(syntheticMicrophone: Bool = false) {
        usesSyntheticMicrophone = syntheticMicrophone
    }

    var captureElapsedTime: TimeInterval? {
        captureEpoch.map { AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime()) - $0 }
    }

    var capturedDurations: (microphone: Double, system: Double) {
        (micPipe?.capturedDuration ?? lastCapturedDurations.microphone,
         systemPipe?.capturedDuration ?? lastCapturedDurations.system)
    }

    func setPaused(_ paused: Bool) throws {
        guard state == .recording else { throw CaptureError.message("No active recording to pause or resume.") }
        micPipe?.setPaused(paused)
        systemPipe?.setPaused(paused)
    }

    /// Creation-owned handle; process-private devices may be absent from global enumeration.
    var activeSystemCaptureDevice: AudioObjectID? {
        state == .recording && aggregate != kAudioObjectUnknown ? aggregate : nil
    }

    /// AVAudioEngine inputNode can raise an Objective-C exception without an input.
    func microphoneInputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &device), "Reading default microphone device")
        guard device != kAudioObjectUnknown else {
            throw CaptureError.message("No microphone input device is available. Connect or select a microphone before recording.")
        }
        return device
    }

    /// Request consent before the model reserves a meeting or starts any devices.
    func authorizeMicrophone() async throws {
        if usesSyntheticMicrophone { return }
        _ = try microphoneInputDevice()
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard authorized else {
            throw CaptureError.message("Microphone access is denied. Enable it for Hush in System Settings → Privacy & Security → Microphone.")
        }
    }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws {
        guard state == .idle else { throw CaptureError.message("A recording is already active or starting.") }
        state = .starting
        captureError = nil
        lastCapturedDurations = (microphone: 0, system: 0)
        lastSystemCaptureFormat = nil
        generation &+= 1
        let activeGeneration = generation
        do {
            try await authorizeMicrophone()
            guard state == .starting else { throw CaptureError.message("Recording was cancelled while requesting microphone access.") }
            let epoch = AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime())
            captureEpoch = epoch
            let failure: @Sendable (Error) -> Void = { [weak self] error in
                Task { @MainActor [weak self] in await self?.captureFailed(error, generation: activeGeneration) }
            }
            let mic: CapturePipe
            if usesSyntheticMicrophone {
                mic = try CapturePipe(channel: .me, rate: SyntheticMicrophone.sampleRate,
                                      emit: onChunk, failure: failure)
                micPipe = mic
                syntheticMic = try SyntheticMicrophone(pipe: mic, epoch: epoch)
            } else {
                let engine = AVAudioEngine()
                self.engine = engine
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0,
                      format.commonFormat == .pcmFormatFloat32 else {
                    throw CaptureError.message("No usable Float32 microphone input device is available.")
                }
                mic = try CapturePipe(channel: .me, rate: format.sampleRate, emit: onChunk, failure: failure)
                micPipe = mic
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                    let timestamp = (time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) :
                        AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime())) - epoch
                    mic.receive(buffer.audioBufferList, timestamp: max(0, timestamp))
                }
                micTapInstalled = true
            }
            try createSystemCapture(epoch: epoch, emit: onChunk, failure: failure)
            if let engine {
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { _ in failure(CaptureError.message("The microphone configuration changed. Restart recording after selecting a working device.")) }
                engine.prepare()
                try engine.start()
            }
            state = .recording
            mic.activate()
            systemPipe?.activate()
            syntheticMic?.start()
        } catch {
            releaseDevices()
            if let micPipe { _ = await micPipe.finish(deliver: false) }
            if let systemPipe { _ = await systemPipe.finish(deliver: false) }
            micPipe = nil
            systemPipe = nil
            state = .idle
            captureEpoch = nil
            throw error
        }
    }

    func stop() async throws {
        if let stopTask { return try await stopTask.value }
        if state == .starting { state = .stopping; return }
        if state == .stopping { return } // Startup cancellation still awaits OS consent.
        guard state == .recording else {
            let error = captureError
            captureError = nil
            if let error { throw error }
            return
        }
        state = .stopping
        let task = Task { @MainActor in
            defer { self.stopTask = nil; self.state = .idle }
            try await self.finishCapture()
        }
        stopTask = task
        try await task.value
    }

    private func finishCapture() async throws {
        releaseDevices()
        let micResult = await micPipe?.finish()
        let systemResult = await systemPipe?.finish()
        lastCapturedDurations = (microphone: micResult?.duration ?? 0, system: systemResult?.duration ?? 0)
        micPipe = nil
        systemPipe = nil
        captureEpoch = nil
        let error = captureError ?? micResult?.error ?? systemResult?.error
        captureError = nil
        if let error { throw error }
    }

    private static let meetingApplications: [(bundle: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave")
    ]

    /// A permission-free, best-effort consent-prompt hint, never proof of a meeting.
    /// Reads only Core Audio process activity/identity and running app display names.
    static func activeMeetingApps() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, Int(size) % MemoryLayout<AudioObjectID>.size == 0 else { return [] }
        var processes = [AudioObjectID](repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = processes.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        let count = min(processes.count, Int(size) / MemoryLayout<AudioObjectID>.size)
        var names = Set<String>()
        let applications = NSWorkspace.shared.runningApplications
        for process in processes.prefix(count) {
            address.mSelector = kAudioProcessPropertyIsRunningInput
            var running: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr,
                  running != 0 else { continue }
            address.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0
            size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr,
                  pid > 0, pid != getpid() else { continue }
            let application = NSRunningApplication(processIdentifier: pid)
            var bundle = application?.bundleIdentifier
            if bundle == nil {
                // Browser audio may belong to a helper rather than the main app.
                address.mSelector = kAudioProcessPropertyBundleID
                var value: Unmanaged<CFString>?
                size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                let result = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
                if result == noErr, let value { bundle = value.takeRetainedValue() as String }
            }
            guard let bundle, let known = meetingApplications.first(where: {
                bundle == $0.bundle || bundle.hasPrefix($0.bundle + ".")
            }) else { continue }
            let mainApp = applications.first { $0.bundleIdentifier == known.bundle }
            names.insert(mainApp?.localizedName ?? known.name)
        }
        return names.sorted()
    }

    nonisolated static func chunkFile(_ url: URL, channel: AudioChannel = .them) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw CaptureError.message("The audio file has no readable channels.")
        }
        var chunks: [AudioChunk] = []
        let chunker = try SampleChunker(channel: channel, rate: format.sampleRate) { chunks.append($0) }
        var mono = [Float](repeating: 0, count: 4096)
        while file.framePosition < file.length {
            let position = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw CaptureError.message("The audio file ended before its declared frame count.")
            }
            let count = Int(buffer.frameLength)
            for frame in 0..<count {
                var sample: Float = 0
                for channel in 0..<Int(format.channelCount) { sample += channels[channel][frame] }
                mono[frame] = sample / Float(format.channelCount)
            }
            mono.withUnsafeBufferPointer { samples in
                chunker.consume(UnsafeBufferPointer(rebasing: samples[..<count]),
                                timestamp: Double(position) / format.sampleRate)
            }
        }
        chunker.finish()
        guard !chunks.isEmpty else { throw CaptureError.message("The audio file contains no audible audio above the silence threshold (−50 dBFS).") }
        return chunks
    }

    private func createSystemCapture(epoch: Double, emit: @escaping @Sendable (AudioChunk) -> Void,
                                     failure: @escaping @Sendable (Error) -> Void) throws {
        var pid = getpid()
        var ownProcess = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess), "Identifying app audio process")
        guard ownProcess != kAudioObjectUnknown else { throw CaptureError.message("Core Audio could not identify this app's audio process.") }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcess])
        description.name = "Hush system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try checked(AudioHardwareCreateProcessTap(description, &processTap), "Creating system audio tap")
        var stream = AudioStreamBasicDescription()
        address.mSelector = kAudioTapPropertyFormat
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checked(AudioObjectGetPropertyData(processTap, &address, 0, nil, &size, &stream), "Reading system audio format")
        guard stream.mFormatID == kAudioFormatLinearPCM,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              stream.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              stream.mBitsPerChannel == 32, stream.mChannelsPerFrame > 0 else {
            throw CaptureError.message("The system audio tap does not provide supported Float32 PCM.")
        }
        let pipe = try CapturePipe(channel: .them, rate: stream.mSampleRate, emit: emit, failure: failure)
        systemPipe = pipe
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hush Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try checked(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Creating private capture device")
        try checked(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, time, _, _ in
            let timestamp = AVAudioTime.seconds(forHostTime: time.pointee.mHostTime) - epoch
            pipe.receive(input, timestamp: max(0, timestamp))
        }, "Installing system audio callback")
        guard let ioProc else { throw CaptureError.message("Core Audio did not create a system audio callback.") }
        try checked(AudioDeviceStart(aggregate, ioProc), "Starting system audio capture")
        if usesSyntheticMicrophone {
            lastSystemCaptureFormat = "pipeRate=\(stream.mSampleRate); start={\(systemCaptureFormatDiagnostic())}"
        }
        // A tap's format can change when the default output device changes. Do not
        // reinterpret new-format bytes using a stale sample clock.
        let device = aggregate
        let tap = processTap
        let expectedRate = stream.mSampleRate
        let expectedFlags = stream.mFormatFlags
        let expectedChannels = stream.mChannelsPerFrame
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Hush.audio.health"))
        timer.setEventHandler {
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var alive: UInt32 = 0
            var bytes = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &alive)
            guard status == noErr, alive != 0 else {
                pipe.fail(CaptureError.message("The system audio capture device is no longer available."))
                return
            }
            property.mSelector = kAudioTapPropertyFormat
            var current = AudioStreamBasicDescription()
            bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let formatStatus = AudioObjectGetPropertyData(tap, &property, 0, nil, &bytes, &current)
            if formatStatus != noErr || current.mSampleRate != expectedRate ||
                current.mFormatFlags != expectedFlags || current.mChannelsPerFrame != expectedChannels {
                pipe.fail(CaptureError.message("The system audio format changed. Restart recording after selecting a working output device."))
            }
        }
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.resume()
        healthTimer = timer
    }

    private func systemCaptureFormatDiagnostic() -> String {
        func describe(_ format: AudioStreamBasicDescription) -> String {
            "rate=\(format.mSampleRate),id=\(format.mFormatID),flags=\(format.mFormatFlags)," +
            "channels=\(format.mChannelsPerFrame),bits=\(format.mBitsPerChannel),bytesPerFrame=\(format.mBytesPerFrame)"
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var tapFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let tapStatus = AudioObjectGetPropertyData(processTap, &address, 0, nil, &size, &tapFormat)
        var fields = ["tapStatus=\(tapStatus),tap=(\(describe(tapFormat)))"]
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var nominalRate = 0.0
        size = UInt32(MemoryLayout<Double>.size)
        let nominalStatus = AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &nominalRate)
        fields.append("aggregateNominalStatus=\(nominalStatus),aggregateNominalRate=\(nominalRate)")
        address.mSelector = kAudioDevicePropertyStreams
        address.mScope = kAudioObjectPropertyScopeInput
        size = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size)
        guard sizeStatus == noErr, size > 0,
              Int(size) % MemoryLayout<AudioObjectID>.size == 0 else {
            fields.append("inputStreamsSizeStatus=\(sizeStatus),inputStreamsBytes=\(size)")
            return fields.joined(separator: "; ")
        }
        var streams = [AudioObjectID](repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let streamsStatus = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, $0.baseAddress!)
        }
        fields.append("inputStreamsStatus=\(streamsStatus)")
        if streamsStatus == noErr {
            address.mSelector = kAudioStreamPropertyVirtualFormat
            address.mScope = kAudioObjectPropertyScopeGlobal
            for streamID in streams.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
                var format = AudioStreamBasicDescription()
                var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &bytes, &format)
                fields.append("inputStream=\(streamID),status=\(status),virtual=(\(describe(format)))")
            }
        }
        return fields.joined(separator: "; ")
    }

    private func checked(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CaptureError.coreAudio(operation, status) }
    }

    private func captureFailed(_ error: Error, generation: UInt64) async {
        guard state == .recording, self.generation == generation else { return }
        captureError = error
        let reported = onFailure != nil
        onFailure?(error.localizedDescription)
        do { try await stop() }
        catch {
            // The callback and concurrent stop waiters already received this failure.
            // A deferred, unreported error belongs only to its original recording.
            guard !reported, self.generation == generation else { return }
            captureError = error
        }
    }

    private func releaseDevices() {
        syntheticMic?.stop()
        syntheticMic = nil
        healthTimer?.cancel()
        healthTimer = nil
        if usesSyntheticMicrophone, aggregate != kAudioObjectUnknown {
            lastSystemCaptureFormat = (lastSystemCaptureFormat ?? "") +
                "; stop={\(systemCaptureFormatDiagnostic())}"
        }
        let cleanupError = Self.destroyDevices(engine: engine, micTapInstalled: micTapInstalled,
            observer: configurationObserver, aggregate: aggregate, ioProc: ioProc, tap: processTap)
        if captureError == nil { captureError = cleanupError }
        configurationObserver = nil
        engine = nil
        micTapInstalled = false
        ioProc = nil
        aggregate = kAudioObjectUnknown
        processTap = kAudioObjectUnknown
    }

    private nonisolated static func destroyDevices(engine: AVAudioEngine?, micTapInstalled: Bool,
        observer: NSObjectProtocol?, aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID?,
        tap: AudioObjectID) -> Error? {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
        if micTapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        engine?.reset()
        var error: Error?
        func check(_ status: OSStatus, _ operation: String) {
            if status != noErr && error == nil { error = CaptureError.coreAudio(operation, status) }
        }
        if let ioProc, aggregate != kAudioObjectUnknown {
            check(AudioDeviceStop(aggregate, ioProc), "Stopping system audio capture")
            check(AudioDeviceDestroyIOProcID(aggregate, ioProc), "Releasing system audio callback")
        }
        if aggregate != kAudioObjectUnknown {
            check(AudioHardwareDestroyAggregateDevice(aggregate), "Releasing capture device")
        }
        if tap != kAudioObjectUnknown {
            check(AudioHardwareDestroyProcessTap(tap), "Releasing system audio tap")
        }
        return error
    }

    deinit {
        syntheticMic?.stop()
        healthTimer?.cancel()
        _ = Self.destroyDevices(engine: engine, micTapInstalled: micTapInstalled,
            observer: configurationObserver, aggregate: aggregate, ioProc: ioProc, tap: processTap)
    }
}
