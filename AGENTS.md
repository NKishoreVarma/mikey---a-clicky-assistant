# Mikey - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Mikey is a macOS menu bar companion app forked from farzaa/clicky (MIT). Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

**Architecture direction:** Mikey App → Mikey Brain (future). Currently the app talks directly to Claude via a Cloudflare Worker proxy. The eventual target is `ClientContext → Mikey Brain API → BrainResponse`. Do not prematurely rewrite the interaction layer.

All API keys live on a Cloudflare Worker proxy — set `WorkerBaseURL` in `mikey/Info.plist` before building. Nothing sensitive ships in the app binary.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: No-op stub in `ClickyAnalytics.swift` — wire your own if needed

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets. Set `WorkerBaseURL` in `mikey/Info.plist` to your deployed worker URL.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Mikey" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Worker URL**: Both Claude chat and AssemblyAI token calls derive from `WorkerBaseURL` in `Info.plist` via `AppBundleConfiguration`. Update that single key to point to a different worker deployment without touching Swift code.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `mikeyApp.swift` | ~65 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate`. No Sparkle updater — add your own feed when ready. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content. Shows companion status, push-to-talk instructions, model picker, permissions UI, quit button. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display, cursor screen first. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from `{WorkerBaseURL}/transcribe-token`, opens an AssemblyAI v3 websocket, streams PCM16 audio. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription fallback (OpenAI Whisper). |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription (Apple Speech framework). |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. PCM16 mono, WAV payloads. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Listen-only CGEvent tap, publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to `{WorkerBaseURL}/tts`, plays back via AVAudioPlayer. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. |
| `ClickyAnalytics.swift` | ~28 | No-op analytics stub. All call sites compile unchanged. Wire your own analytics here. |
| `WindowPositionManager.swift` | ~262 | Window placement, Screen Recording permission flow, accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader. Reads keys from Info.plist by name. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude SSE), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

**IMPORTANT: Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

```bash
# 1. Deploy your Cloudflare Worker (see worker/ directory)
cd worker && npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put ELEVENLABS_VOICE_ID
npx wrangler deploy

# 2. Set your worker URL in mikey/Info.plist
# Edit the WorkerBaseURL key to your deployed worker URL.

# 3. Open in Xcode
open mikey.xcodeproj

# 4. Select the mikey scheme, set your signing team, Cmd+R
```

**Known non-blocking warnings**: Swift 6 concurrency warnings, deprecated onChange warning in OverlayWindow.swift. Do NOT fix these.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put ELEVENLABS_VOICE_ID

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

- Be as clear and specific as possible
- **Optimize for clarity over concision.** A developer with zero context should immediately understand what a variable or method does
- Use longer names when it improves clarity. Do NOT use single-character variable names
- When passing props to functions, keep the same names as the original variable

### Code Clarity

- **Clear is better than clever**
- Write more lines if additional lines improve readability
- When a variable/method name alone cannot explain something, add a comment explaining WHY

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover

### Do NOT

- Do not add features, refactor, or make improvements beyond what was asked
- Do not fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions
- Do not implement Operational Brain features yet (autonomous actions, Gmail, etc.)
- Do not add PostHog or any third-party analytics without explicit instruction

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Attribution: Original Clicky © Farza Majeed, MIT License
