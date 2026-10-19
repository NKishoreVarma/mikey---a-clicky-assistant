// MikeyPermissionService.swift
// mikey
//
// Authoritative permission logic layer. All macOS TCC checks, grant flows,
// and UserDefaults cache management live here. CompanionManager owns one
// instance and reads every permission state through it.
//
// Architecture:
//   MikeyPermissionService   ← single source of truth for all four permissions
//         ↓
//   CompanionManager         ← re-publishes state for SwiftUI
//         ↓
//   CompanionPanelView       ← renders permission rows
//
// UserDefaults usage:
//   Only used as a cache for permissions that macOS cannot reliably report
//   synchronously. Never used as the sole source — macOS TCC is always
//   consulted first. The cache only prevents known false-negatives.

import AVFoundation
import ApplicationServices
import AppKit
import ScreenCaptureKit

// MARK: - Permission status

/// Authoritative status for a single macOS permission.
enum MikeyPermissionStatus: Equatable {
    /// macOS TCC (or an authoritative API) has confirmed the permission is granted.
    case granted
    /// The user has not yet been asked, or the state is genuinely indeterminate.
    /// The UI should offer a Grant button.
    case notDetermined
    /// The user or system has explicitly blocked the permission.
    /// The UI should offer a path to System Settings.
    case denied
}

// MARK: - Service

/// Single authoritative source for all four Mikey permissions.
/// All checks use real macOS APIs. UserDefaults is used only as a cache for
/// screen recording (known macOS false-negative behavior) and screen content
/// (no synchronous TCC API exists for ScreenCaptureKit).
@MainActor
final class MikeyPermissionService {

    // MARK: - UserDefaults keys (Mikey-scoped)

    /// Cache key written whenever CGPreflightScreenCaptureAccess() returns true.
    /// Protects against macOS returning a transient false-negative on launch/rebuild.
    static let screenRecordingConfirmedKey = "mikey.screenRecordingConfirmed"

    /// Cache key written after a successful SCScreenshotManager capture.
    /// There is no synchronous TCC API for ScreenCaptureKit; this cache is the
    /// only way to persist the granted state across sessions without re-prompting.
    static let screenContentConfirmedKey = "mikey.screenContentConfirmed"

    // Legacy keys from the original Clicky/learningbuddy codebase.
    // Migrated to the Mikey-scoped keys on first run; see migrateLegacyKeys().
    private static let legacyScreenRecordingKey =
        "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"
    private static let legacyScreenContentKey = "hasScreenContentPermission"

    // MARK: - Per-launch prompt tracking

    // These track whether we've already shown the system prompt this session.
    // macOS only shows its native dialog once; subsequent taps should open Settings.
    private static var hasAttemptedAccessibilityPromptThisLaunch = false
    private static var hasAttemptedScreenRecordingPromptThisLaunch = false

    // MARK: - Synchronous status checks

    /// Reads the actual AVFoundation microphone authorization state.
    static func microphoneStatus() -> MikeyPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// Reads the macOS Accessibility TCC state via AXIsProcessTrusted().
    ///
    /// Returns .notDetermined when false because AXIsProcessTrusted() cannot
    /// distinguish "never asked" from "denied" — both return false. Using
    /// .notDetermined ensures the UI always offers the Grant path.
    ///
    /// IMPORTANT — macOS TCC rebuild behavior:
    /// On development (Xcode) builds, macOS can revoke the Accessibility TCC
    /// entry when the app binary changes (every Cmd+R rebuild). This is a
    /// platform-level limitation; Mikey cannot work around it. The user must
    /// re-add the app in System Settings > Privacy & Security > Accessibility
    /// after each rebuild. Distribution builds (notarized, same cert) are not
    /// affected because the binary path and signing identity remain stable.
    static func accessibilityStatus() -> MikeyPermissionStatus {
        return AXIsProcessTrusted() ? .granted : .notDetermined
    }

    /// Reads the Screen Recording TCC state with a UserDefaults cache fallback.
    ///
    /// macOS occasionally returns false from CGPreflightScreenCaptureAccess()
    /// immediately after launch or after a binary replacement even when the user
    /// has already granted the permission. The cache ensures a transient
    /// false-negative cannot downgrade a confirmed grant to notDetermined and
    /// reopen the onboarding flow.
    ///
    /// The cache is invalidated automatically when macOS genuinely revokes the
    /// permission: the next positive confirmation from CGPreflightScreenCaptureAccess()
    /// re-writes the cache, but if the permission is gone for an extended period the
    /// user will see the screen recording row appear — which is the correct behavior.
    static func screenRecordingStatus() -> MikeyPermissionStatus {
        let hasItNow = CGPreflightScreenCaptureAccess()
        if hasItNow {
            UserDefaults.standard.set(true, forKey: screenRecordingConfirmedKey)
            return .granted
        }
        let hadItBefore = UserDefaults.standard.bool(forKey: screenRecordingConfirmedKey)
        return hadItBefore ? .granted : .notDetermined
    }

    /// Reads the Screen Content (ScreenCaptureKit) grant state from UserDefaults.
    ///
    /// There is no synchronous TCC API for ScreenCaptureKit; calling
    /// SCShareableContent without prior trust can trigger the picker dialog.
    /// The UserDefaults cache written by requestScreenContentPermission() is the
    /// authoritative source across sessions. If the cache is absent (fresh install
    /// or cleared UserDefaults), returns .notDetermined so the Grant button appears.
    static func screenContentStatus() -> MikeyPermissionStatus {
        let hasCache = UserDefaults.standard.bool(forKey: screenContentConfirmedKey)
        return hasCache ? .granted : .notDetermined
    }

    // MARK: - Full permission snapshot (used by CompanionManager.refreshAllPermissions)

    struct PermissionSnapshot {
        let microphone: MikeyPermissionStatus
        let accessibility: MikeyPermissionStatus
        let screenRecording: MikeyPermissionStatus
        let screenContent: MikeyPermissionStatus

        var allGranted: Bool {
            microphone == .granted &&
            accessibility == .granted &&
            screenRecording == .granted &&
            screenContent == .granted
        }
    }

    /// Returns the current authoritative permission snapshot in one call.
    /// This is what CompanionManager's refreshAllPermissions() should use so all
    /// four checks happen together and there is never a partially-updated state.
    static func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneStatus(),
            accessibility: accessibilityStatus(),
            screenRecording: screenRecordingStatus(),
            screenContent: screenContentStatus()
        )
    }

    // MARK: - Grant request methods

    /// Triggers the macOS accessibility prompt on first tap, then opens System
    /// Settings on subsequent taps within the same launch.
    static func requestAccessibilityPermission() {
        if AXIsProcessTrusted() { return }

        if !hasAttemptedAccessibilityPromptThisLaunch {
            hasAttemptedAccessibilityPromptThisLaunch = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    /// Opens System Settings directly to the Accessibility pane.
    static func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Triggers the native Screen Recording prompt on first tap, then opens System
    /// Settings on subsequent taps within the same launch.
    static func requestScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() { return }

        if !hasAttemptedScreenRecordingPromptThisLaunch {
            hasAttemptedScreenRecordingPromptThisLaunch = true
            _ = CGRequestScreenCaptureAccess()
        } else {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    /// Opens System Settings to the Screen Recording pane.
    static func openScreenRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// Requests microphone access: shows the system prompt on first call;
    /// opens System Settings when already denied.
    static func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    /// Reveals the app bundle in Finder so the user can drag it into the
    /// Accessibility list when it doesn't appear automatically (common with
    /// development/unsigned builds that replaced a previous binary).
    static func revealAppBundleInFinder() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    // MARK: - Screen Content async grant

    /// Triggers the ScreenCaptureKit picker by performing a real screenshot.
    /// This is the only way to grant Screen Content permission — macOS offers
    /// no synchronous preflight API for ScreenCaptureKit without the picker.
    ///
    /// Returns true when the capture succeeded and the confirmed-grant cache was
    /// written to UserDefaults for future sessions.
    static func requestScreenContentPermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else { return false }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 320
            config.height = 240

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let didCapture = image.width > 0 && image.height > 0
            if didCapture {
                UserDefaults.standard.set(true, forKey: screenContentConfirmedKey)
            }
            return didCapture
        } catch {
            return false
        }
    }

    // MARK: - Legacy UserDefaults migration

    /// Migrates legacy UserDefaults keys written by the original Clicky/learningbuddy
    /// codebase to the Mikey-scoped keys. Safe to call every launch — only acts when
    /// the legacy key is present and the new key has not been written yet.
    static func migrateLegacyUserDefaultsKeys() {
        let defaults = UserDefaults.standard

        // Screen recording: com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission → mikey.screenRecordingConfirmed
        if defaults.bool(forKey: legacyScreenRecordingKey),
           !defaults.bool(forKey: screenRecordingConfirmedKey) {
            defaults.set(true, forKey: screenRecordingConfirmedKey)
            defaults.removeObject(forKey: legacyScreenRecordingKey)
        }

        // Screen content: hasScreenContentPermission → mikey.screenContentConfirmed
        if defaults.bool(forKey: legacyScreenContentKey),
           !defaults.bool(forKey: screenContentConfirmedKey) {
            defaults.set(true, forKey: screenContentConfirmedKey)
            defaults.removeObject(forKey: legacyScreenContentKey)
        }
    }

    // MARK: - Private helpers

    private static func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
