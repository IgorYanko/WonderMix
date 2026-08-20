import SwiftUI

@main
struct WonderMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = MixerController.shared

    var body: some Scene {
        MenuBarExtra("WonderMix", systemImage: "slider.horizontal.3") {
            MixerPopoverView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}
