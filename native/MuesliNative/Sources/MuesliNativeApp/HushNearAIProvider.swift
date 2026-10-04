import Foundation
import MuesliCore

/// Native Muesli generation uses the same configured, fail-closed client as Hush chat.
enum HushNearAIProvider {
    @MainActor
    private static func configuration() throws -> (InferenceClient, String) {
        guard let model = MuesliController.current?.hushModel else {
            throw AppError("NEAR AI is unavailable until the encrypted meeting vault is unlocked")
        }
        return (model.client, model.settings.model)
    }

    static func complete(systemPrompt: String, userPrompt: String, model requestedModel: String? = nil) async throws -> String {
        let (client, configuredModel) = try await configuration()
        return try await client.complete(systemPrompt: systemPrompt, userPrompt: userPrompt, model: requestedModel ?? configuredModel)
    }

    static func prepareTranscription() async throws {
        let (client, _) = try await configuration()
        _ = try await client.verify()
    }

    static func transcribe(at url: URL) async throws -> SpeechTranscriptionResult {
        let (client, _) = try await configuration()
        _ = try await client.verify()
        let chunks = try AudioRecorder.chunkFile(url)
        var segments: [SpeechSegment] = []
        segments.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let segment = try await client.transcribe(chunk)
            segments.append(SpeechSegment(start: segment.start, end: segment.end, text: segment.text))
        }
        return SpeechTranscriptionResult(text: segments.map(\.text).joined(separator: "\n"), segments: segments)
    }
}
