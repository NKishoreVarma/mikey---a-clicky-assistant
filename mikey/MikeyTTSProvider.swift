//
//  MikeyTTSProvider.swift
//  mikey
//
//  Protocol surface and factory for TTS backends.
//  CompanionManager talks only to this protocol, never to a concrete client directly.
//

import Foundation

/// Shared interface for all TTS backends (ElevenLabs via Worker, local macOS speech, etc.).
@MainActor
protocol MikeyTTSProvider: AnyObject {
    /// Synthesize and begin playing `text`. Returns as soon as playback starts
    /// (non-blocking), matching ElevenLabs client behavior. Throws on failure.
    func speakText(_ text: String) async throws
    /// Whether TTS audio is currently playing.
    var isPlaying: Bool { get }
    /// Stop any in-progress playback immediately.
    func stopPlayback()
}

/// Reads Info.plist and constructs the correct TTS provider for this build.
///
/// Info.plist keys:
///   MikeyTTSProvider  "local" | "macos" | "elevenlabs"  (default: "elevenlabs")
///   WorkerBaseURL     Cloudflare Worker URL              (ElevenLabs provider only)
///
/// "local" and "macos" are both accepted for the AVSpeechSynthesizer path.
@MainActor
enum MikeyTTSProviderFactory {
    static func makeDefaultProvider(workerBaseURL: String) -> any MikeyTTSProvider {
        let providerKey = AppBundleConfiguration.stringValue(forKey: "MikeyTTSProvider")?
            .lowercased() ?? "elevenlabs"

        switch providerKey {
        case "local", "macos":
            print("🔊 TTS: local macOS AVSpeechSynthesizer")
            return LocalMacOSTTSProvider()
        default:
            print("🔊 TTS: ElevenLabs via Worker proxy")
            return ElevenLabsTTSClient(proxyURL: "\(workerBaseURL)/tts")
        }
    }
}
