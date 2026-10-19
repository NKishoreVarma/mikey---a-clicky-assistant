# Mikey — Intelligent macOS Companion & Cursor Assistant

[![macOS](https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org/)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-blue)](https://developer.apple.com/xcode/swiftui/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Architecture-Local%20%7C%20Cloud%20Hybrid-brightgreen)](#architecture)

Mikey is a native macOS companion app that lives in your menu bar and right alongside your cursor. By holding the push-to-talk hotkey (`Ctrl + Option`), Mikey captures your voice, takes a high-resolution screenshot of your active screen, and provides intelligent, contextual multimodal answers. Mikey can speak aloud with realistic voice synthesis, stream real-time text responses in a floating companion bubble, and fly to/point at referenced UI elements across multiple displays with smooth bezier animations.

> **Local-First & Cloud-Ready**: Mikey supports both 100% offline local AI (Ollama + Apple Speech + macOS TTS) with zero external API keys, as well as high-performance cloud providers (Anthropic Claude 3.7/Sonnet + AssemblyAI streaming + ElevenLabs) via an optional Cloudflare Worker proxy.

---

## Key Highlights

- **Menu Bar LifeCycle (`LSUIElement`)**: No dock clutter, no heavy windows. Lives discreetly in your macOS status bar.
- **Transparent Cursor Companion Overlay**: Renders stateful animations, speech waveforms, streaming markdown text responses, and a glowing directional cursor pointer.
- **Bezier-Arc Element Pointing**: When vision models identify relevant on-screen elements via `[POINT:x,y:label:screenN]` coordinates, Mikey flies smoothly to point directly at them across any connected monitor.
- **Pluggable Architecture**:
  - **LLM Engine (`MikeyLLMProvider`)**: Local Ollama (e.g. `llava`, `llama3.2-vision`) or Anthropic Claude (Sonnet 4.6, Opus 4.6).
  - **Text-to-Speech (`MikeyTTSProvider`)**: Instant offline macOS `AVSpeechSynthesizer` or ultra-realistic ElevenLabs.
  - **Speech-to-Text (`BuddyTranscriptionProvider`)**: Built-in Apple Speech (offline), AssemblyAI real-time WebSocket, or OpenAI Whisper.
- **Low-Latency Push-to-Talk**: Global `Ctrl + Option` detection using a listen-only `CGEvent` tap without stealing keyboard focus from active apps.
- **Robust TCC Permissions Service (`MikeyPermissionService`)**: Centralized manager for Microphone, Accessibility, Screen Recording, and ScreenCaptureKit permissions with persistent caching to eliminate macOS rebuild false-negatives.

---

## System Architecture

```
                                  ┌───────────────────────────────┐
                                  │   macOS Menu Bar (StatusItem) │
                                  └──────────────┬────────────────┘
                                                 │
                                     ┌───────────▼───────────┐
                                     │  CompanionManager     │
                                     │  (Central Controller) │
                                     └─────┬─────┬─────┬─────┘
                     ┌─────────────────────┘     │     └─────────────────────┐
                     ▼                           ▼                           ▼
        ┌─────────────────────────┐ ┌─────────────────────────┐ ┌─────────────────────────┐
        │   MikeyLLMProvider      │ │    MikeyTTSProvider     │ │  TranscriptionProvider  │
        ├─────────────────────────┤ ├─────────────────────────┤ ├─────────────────────────┤
        │ • Ollama (Local/Offline)│ │ • macOS AVSpeech (Local)│ │ • Apple Speech (Local)  │
        │ • Claude (via Worker)   │ │ • ElevenLabs (via Worker│ │ • AssemblyAI WebSocket  │
        │                         │ │                         │ │ • OpenAI Whisper        │
        └─────────────────────────┘ └─────────────────────────┘ └─────────────────────────┘
                     │                           │                           │
                     └─────────────────────┬─────┴───────────────────────────┘
                                           │
                               ┌───────────▼───────────┐
                               │     OverlayWindow     │
                               │  (Transparent NSPanel)│
                               │  • Streaming Bubble   │
                               │  • Waveform Visualizer│
                               │  • Multi-Screen Arc   │
                               └───────────────────────┘
```

---

## Getting Started

### Prerequisites

- **macOS Sonoma 14.2+** (required for modern `ScreenCaptureKit` and multi-monitor APIs)
- **Xcode 15.0+**
- *(Optional for Local Mode)*: [Ollama](https://ollama.com/) installed and running locally
- *(Optional for Cloud Mode)*: Node.js 18+ and a Cloudflare account for the proxy worker

---

### Quick Start: Local-First Mode (100% Free, Zero API Keys)

Mikey is configured out-of-the-box to run entirely locally on your Mac:

1. **Install Ollama** (if you don't already have it):
   ```bash
   brew install ollama
   ollama serve
   ```
2. **Pull a vision-capable model**:
   ```bash
   ollama pull llava
   ```
3. **Verify Settings in `mikey/Info.plist`**:
   - `MikeyLLMProvider`: `ollama`
   - `MikeyOllamaModel`: `llava`
   - `MikeyTTSProvider`: `local`
   - `VoiceTranscriptionProvider`: `apple`
4. **Open in Xcode and Run**:
   ```bash
   open mikey.xcodeproj
   ```
   Select your development signing team, build with **Cmd + R**, and grant requested permissions.

---

### Cloud Mode (Anthropic Claude + ElevenLabs + AssemblyAI)

For production-grade cloud intelligence, Mikey routes external API calls through a secure Cloudflare Worker proxy so API keys are never packaged inside the client binary:

1. **Deploy the Worker**:
   ```bash
   cd worker
   npm install
   npx wrangler secret put ANTHROPIC_API_KEY
   npx wrangler secret put ASSEMBLYAI_API_KEY
   npx wrangler secret put ELEVENLABS_API_KEY
   npx wrangler deploy
   ```
2. **Configure App**:
   In `mikey/Info.plist`, set:
   - `WorkerBaseURL`: `https://your-worker-subdomain.workers.dev`
   - `MikeyLLMProvider`: `anthropic`
   - `MikeyTTSProvider`: `elevenlabs`
   - `VoiceTranscriptionProvider`: `assemblyai`

---

## Configuration Reference (`mikey/Info.plist`)

| Key | Options / Type | Default | Description |
|---|---|---|---|
| `MikeyLLMProvider` | `ollama` \| `anthropic` | `ollama` | Active LLM backend provider |
| `MikeyOllamaURL` | URL String | `http://localhost:11434` | Base endpoint for local Ollama |
| `MikeyOllamaModel` | Model Identifier | `llava` | Ollama model name |
| `MikeyTTSProvider` | `local` \| `elevenlabs` | `local` | Active text-to-speech audio synthesis |
| `VoiceTranscriptionProvider` | `apple` \| `assemblyai` \| `openai` | `apple` | Speech transcription engine |
| `WorkerBaseURL` | URL String | `https://...` | Cloudflare Worker endpoint for cloud mode |
| `MikeyAuthToken` | String | *(optional)* | Shared secret Bearer token for worker proxy auth |

---

## Repository & Branching Structure

This repository follows a clean, professional git flow with designated branches:

- **`main`**: Production-ready, fully integrated release branch.
- **`develop`**: Integration and staging branch for ongoing development.
- **`feature/modular-providers`**: Pluggable protocol abstractions (`MikeyLLMProvider`, `MikeyTTSProvider`, Ollama integration, local macOS TTS, worker bearer token auth).
- **`feature/permission-service`**: Centralized `MikeyPermissionService` with intelligent macOS TCC cache fallback and screen content validation.
- **`feature/branding-and-cleanup`**: Project renaming, bundle identifier unification (`com.mikey.app`), menu bar icon integration, test suite migration (`mikeyTests`), and analytics stubbing.

---

## Permissions Guide

Mikey requires four system permissions on macOS:
1. **Microphone**: Captured via `AVAudioEngine` exclusively while `Ctrl + Option` is held.
2. **Accessibility**: Monitors global modifier state via a passive, listen-only `CGEvent` tap.
3. **Screen Recording**: Captures the active display when push-to-talk completes.
4. **Screen Content**: Granted via ScreenCaptureKit for non-intrusive window/screen analysis.

---

## Attribution & License

- Forked from [Clicky](https://github.com/farzaa/clicky) by **Farza Majeed**.
- Licensed under the **MIT License**. See [LICENSE](LICENSE) for details.
