import Foundation

/// The fork keeps Hush's cloud trust boundary; local model choices remain available.
enum HushInferencePolicy {
    static func permits(backend: String, config: AppConfig) -> Bool {
        let endpoint: String
        switch backend.lowercased() {
        case "near_ai":
            return true // The shared NEAR client verifies before it sends any content.
        case "ollama":
            endpoint = config.ollamaURL.isEmpty ? "http://localhost:11434" : config.ollamaURL
        case "lmstudio":
            endpoint = config.lmStudioURL.isEmpty ? "http://localhost:1234" : config.lmStudioURL
        case "custom_llm":
            endpoint = config.customLLMURL
        default:
            return false
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return false }
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }

    static func validate(backend: String, config: AppConfig) async throws {
        let isHush: Bool
        if Bundle.main.bundleIdentifier == "ai.privategranola.local" {
            isHush = true
        } else {
            isHush = await MainActor.run { MuesliController.current?.hushModel != nil }
        }
        guard !isHush || permits(backend: backend, config: config) else {
            throw AppError("Hush allows local loopback models or verified NEAR AI. This provider would send private content outside that trust policy.")
        }
    }
}
