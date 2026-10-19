//
//  LocalMacOSTTSProvider.swift
//  mikey
//
//  Local TTS backend using macOS AVSpeechSynthesizer.
//  Free, fully offline, no API key or network connection required.
//

import AVFoundation
import Foundation

@MainActor
final class LocalMacOSTTSProvider: MikeyTTSProvider {
    private let synthesizer = AVSpeechSynthesizer()

    func speakText(_ text: String) async throws {
        stopPlayback()

        let utterance = AVSpeechUtterance(string: text)
        // Slightly above AVSpeechUtteranceDefaultSpeechRate (0.5) for a more
        // natural conversational pace without sounding rushed.
        utterance.rate = 0.55
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.9

        synthesizer.speak(utterance)
        print("🔊 Local TTS: speaking \(text.count) chars")
        
    }

    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    func stopPlayback() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}
