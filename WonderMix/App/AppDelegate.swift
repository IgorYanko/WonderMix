import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            MixerController.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Must run before the process exits, otherwise the private aggregates and taps
        // outlive the app and every app we tapped stays muted.
        MainActor.assumeIsolated {
            MixerController.shared.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
