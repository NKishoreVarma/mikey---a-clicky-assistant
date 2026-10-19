//
//  mikeyTests.swift
//  mikeyTests
//

import CoreGraphics
import Testing
@testable import mikey

@MainActor
struct mikeyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func screenRecordingUserDefaultsCachePreventsFalseNegativeDowngrade() async throws {
        // Simulate the known macOS false-negative: CGPreflightScreenCaptureAccess()
        // returns false even though the user previously confirmed the permission.
        // MikeyPermissionService must fall back to the UserDefaults cache and
        // return .granted rather than downgrading to .notDetermined.
        let defaults = UserDefaults.standard
        let testKey = MikeyPermissionService.screenRecordingConfirmedKey

        // Precondition: ensure cache is set as if user previously confirmed.
        defaults.set(true, forKey: testKey)
        defer { defaults.removeObject(forKey: testKey) }

        // If CGPreflightScreenCaptureAccess() is false in this test environment,
        // the cache must keep the status as .granted.
        // If it is true (test machine has screen recording), the result is also .granted.
        // Either way the expectation holds.
        let status = MikeyPermissionService.screenRecordingStatus()
        #expect(status == .granted)
    }

    @Test func screenRecordingNotDeterminedWhenNoCacheAndNoSystemPermission() async throws {
        // When there is no UserDefaults cache AND CGPreflightScreenCaptureAccess()
        // returns false, the status should be .notDetermined (never granted),
        // not .denied (which would imply the user actively blocked it).
        let defaults = UserDefaults.standard
        let testKey = MikeyPermissionService.screenRecordingConfirmedKey
        let previousValue = defaults.object(forKey: testKey)
        defaults.removeObject(forKey: testKey)
        defer {
            if let prev = previousValue {
                defaults.set(prev, forKey: testKey)
            }
        }

        // If CGPreflightScreenCaptureAccess() is true (machine has permission),
        // this test cannot verify the .notDetermined path — skip it gracefully.
        guard !CGPreflightScreenCaptureAccess() else { return }

        let status = MikeyPermissionService.screenRecordingStatus()
        #expect(status == .notDetermined)
    }
}
