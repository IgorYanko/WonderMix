import Foundation

/// Pure gates used by `MixerController` — kept free of Core Audio so unit tests can cover them.
enum MixerRuntimePolicy {
    /// Taps/aggregates only run when the soft power switch is on and capture permission is granted.
    static func shouldDriveAudio(isEnabled: Bool, hasPermission: Bool) -> Bool {
        isEnabled && hasPermission
    }

    /// Inactive apps stay hidden unless the user opted in, or they have a non-default saved state.
    static func isVisible(
        isRunningOutput: Bool,
        showInactiveApps: Bool,
        hasCustomState: Bool
    ) -> Bool {
        if showInactiveApps { return true }
        return isRunningOutput || hasCustomState
    }
}
