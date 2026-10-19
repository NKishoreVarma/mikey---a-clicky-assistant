//
//  MikeyLLMProvider.swift
//  mikey
//
//  Protocol surface and factory for LLM backends.
//  CompanionManager talks only to this protocol, never to a concrete provider directly.
//

import Foundation

/// Shared interface for all LLM backends (Anthropic via Worker, Ollama, etc.).
protocol MikeyLLMProvider: AnyObject {
    /// Active model name. Providers that derive the model from Info.plist
    /// (e.g. OllamaLLMProvider) may ignore writes from the panel model picker.
    var model: String { get set }

    /// Send images + conversation context, stream response text chunks to the UI,
    /// and return the full accumulated text when the stream ends.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

/// Reads Info.plist keys and constructs the correct LLM provider for this build.
///
/// Info.plist keys:
///   MikeyLLMProvider   "ollama" | "anthropic"   (default: "anthropic")
///   MikeyOllamaURL     base URL for Ollama       (default: http://localhost:11434)
///   MikeyOllamaModel   Ollama model name         (default: llava)
///   WorkerBaseURL      Cloudflare Worker URL     (Anthropic provider only)
enum MikeyLLMProviderFactory {
    static func makeDefaultProvider() -> any MikeyLLMProvider {
        let providerKey = AppBundleConfiguration.stringValue(forKey: "MikeyLLMProvider")?
            .lowercased() ?? "anthropic"

        switch providerKey {
        case "ollama":
            let ollamaBaseURL = AppBundleConfiguration.stringValue(forKey: "MikeyOllamaURL")
                ?? "http://localhost:11434"
            let ollamaModel = AppBundleConfiguration.stringValue(forKey: "MikeyOllamaModel")
                ?? "llava"
            print("🤖 LLM: Ollama at \(ollamaBaseURL) model=\(ollamaModel)")
            return OllamaLLMProvider(baseURL: ollamaBaseURL, model: ollamaModel)

        default:
            let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
                ?? "https://your-worker-name.your-subdomain.workers.dev"
            let savedModel = UserDefaults.standard.string(forKey: "selectedClaudeModel")
                ?? "claude-sonnet-4-6"
            print("🤖 LLM: Anthropic via Worker (\(savedModel))")
            return ClaudeAPI(proxyURL: "\(workerBaseURL)/chat", model: savedModel)
        }
    }
}
