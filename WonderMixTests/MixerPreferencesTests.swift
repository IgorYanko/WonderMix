import XCTest
@testable import WonderMix

@MainActor
final class MixerPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: MixerPreferences!

    override func setUp() {
        super.setUp()
        suiteName = "WonderMixTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        preferences = MixerPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        preferences = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testIsEnabledDefaultsToTrueWhenUnset() {
        XCTAssertTrue(preferences.isEnabled)
    }

    func testIsEnabledPersistsAcrossInstances() {
        preferences.isEnabled = false
        let reloaded = MixerPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled)

        preferences.isEnabled = true
        let enabledAgain = MixerPreferences(defaults: defaults)
        XCTAssertTrue(enabledAgain.isEnabled)
    }

    func testShowInactiveAppsDefaultsToFalse() {
        XCTAssertFalse(preferences.showInactiveApps)
    }

    func testVolumeIsClamped() {
        preferences.setVolume(2.5, forBundleID: "com.example.app")
        XCTAssertEqual(preferences.state(forBundleID: "com.example.app").volume, 1.5)

        preferences.setVolume(-1, forBundleID: "com.example.app")
        XCTAssertEqual(preferences.state(forBundleID: "com.example.app").volume, 0)
    }

    func testMuteAndDeviceRoundTrip() {
        preferences.setMuted(true, forBundleID: "com.example.app")
        preferences.setOutputDeviceUID("uid-speakers", forBundleID: "com.example.app")

        let reloaded = MixerPreferences(defaults: defaults)
        let state = reloaded.state(forBundleID: "com.example.app")
        XCTAssertTrue(state.isMuted)
        XCTAssertEqual(state.outputDeviceUID, "uid-speakers")
        XCTAssertEqual(state.volume, 1.0)
    }

    func testResetAllClearsAppStatesButKeepsToggles() {
        preferences.isEnabled = false
        preferences.showInactiveApps = true
        preferences.setVolume(0.4, forBundleID: "com.example.app")
        preferences.resetAll()

        XCTAssertEqual(preferences.state(forBundleID: "com.example.app"), .default)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(preferences.showInactiveApps)
    }
}
