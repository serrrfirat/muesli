import Foundation

struct AudioFrame: Sendable {
    let channel: AudioChannel
    let samples: [Float]
    let sampleRate: Double
    let timestamp: TimeInterval
}
enum AudioChannel: String, Codable, Sendable { case me, them }
struct AudioChunk: Codable, Sendable {
    var id: UUID = UUID()
    let channel: AudioChannel
    let start: TimeInterval
    let end: TimeInterval
    let data: Data
    let mimeType: String
}
struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    let chunkID: UUID
    let channel: AudioChannel
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}
struct Meeting: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var startedAt: Date = Date()
    var segments: [TranscriptSegment] = []
    var scratchNotes: String = ""
    var summary: String = ""
    var embeddings: [[Float]] = []
}
struct AppSettings: Codable, Sendable {
    var endpointURL: String = "https://cloud-api.near.ai"
    var model: String = "z-ai/glm-5.3-flash"
    var template: String = "General"
    var customTemplate: String = ""
    var backupDirectory: String = ""
}
struct Quota: Codable, Sendable {
    let stakedYocto: String
    let creditsUsd: Double
    let usedUsd: Double
}
struct TrustStatus: Codable, Sendable {
    let state: String
    let detail: String
    let verifiedAt: Date?
}
