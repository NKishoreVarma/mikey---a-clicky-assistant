//
//  OllamaLLMProvider.swift
//  mikey
//
//  Local LLM backend powered by Ollama (http://localhost:11434 by default).
//  Requires Ollama to be installed and running on the user's Mac.
//  Use a vision-capable model (llava, moondream, llama3.2-vision) for screen context.
//
//  Route: macOS app → OllamaLLMProvider → localhost:11434/api/chat
//  The Cloudflare Worker is NOT involved — this calls localhost directly from Swift.
//

import Foundation

final class OllamaLLMProvider: MikeyLLMProvider {
    /// Active Ollama model. Set from MikeyOllamaModel in Info.plist at init time.
    /// The Claude model picker in the panel may write a Claude model name here,
    /// which Ollama will reject — use Info.plist to set the correct Ollama model.
    var model: String

    private let chatURL: URL
    private let session: URLSession

    init(baseURL: String, model: String) {
        self.model = model
        self.chatURL = URL(string: "\(baseURL)/api/chat")!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var messages: [[String: Any]] = []

        // Ollama uses a system role message for the system prompt
        messages.append(["role": "system", "content": systemPrompt])

        // Prior conversation turns carry text only — screenshots are not preserved
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Current user turn: combine image labels + prompt in content,
        // and pass raw base64 image bytes in the Ollama "images" field.
        var contentParts: [String] = []
        var base64Images: [String] = []
        for image in images {
            contentParts.append(image.label)
            base64Images.append(image.data.base64EncodedString())
        }
        contentParts.append(userPrompt)

        var currentUserMessage: [String: Any] = [
            "role": "user",
            "content": contentParts.joined(separator: "\n")
        ]
        if !base64Images.isEmpty {
            currentUserMessage["images"] = base64Images
        }
        messages.append(currentUserMessage)

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = bodyData

        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🦙 Ollama streaming: \(String(format: "%.1f", payloadMB))MB, model=\(model), \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OllamaLLM",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama returned an invalid HTTP response. Is Ollama running at \(chatURL.host ?? "localhost")?"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorLines: [String] = []
            for try await line in byteStream.lines {
                errorLines.append(line)
            }
            let errorBody = errorLines.joined(separator: "\n")
            throw NSError(
                domain: "OllamaLLM",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Ollama error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Ollama streams NDJSON: one JSON object per newline.
        // Each chunk: {"message": {"content": "text fragment"}, "done": false}
        // Final chunk: {"done": true}
        var accumulatedText = ""

        for try await line in byteStream.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            guard let lineData = trimmedLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let messageDict = json["message"] as? [String: Any],
               let contentChunk = messageDict["content"] as? String,
               !contentChunk.isEmpty {
                accumulatedText += contentChunk
                let currentText = accumulatedText
                await onTextChunk(currentText)
            }

            if let done = json["done"] as? Bool, done {
                break
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        print("🦙 Ollama complete: \(accumulatedText.count) chars in \(String(format: "%.1f", duration))s")
        return (text: accumulatedText, duration: duration)
    }
}
