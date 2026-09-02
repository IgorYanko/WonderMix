import SwiftUI

@main
struct WonderMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = MixerController.shared

    var body: some Scene {
        MenuBarExtra {
            MixerPopoverView()
                .environmentObject(controller)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .opacity(controller.isEnabled ? 1 : 0.45)
                .accessibilityLabel("WonderMix")
        }
        .menuBarExtraStyle(.window)
    }
}
