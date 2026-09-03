import XCTest
@testable import WonderMix

final class MixerRuntimePolicyTests: XCTestCase {
    func testShouldDriveAudioRequiresEnabledAndPermission() {
        XCTAssertTrue(MixerRuntimePolicy.shouldDriveAudio(isEnabled: true, hasPermission: true))
        XCTAssertFalse(MixerRuntimePolicy.shouldDriveAudio(isEnabled: false, hasPermission: true))
        XCTAssertFalse(MixerRuntimePolicy.shouldDriveAudio(isEnabled: true, hasPermission: false))
        XCTAssertFalse(MixerRuntimePolicy.shouldDriveAudio(isEnabled: false, hasPermission: false))
    }

    func testVisibilityHidesInactiveUnlessOptedInOrCustomState() {
        XCTAssertTrue(
            MixerRuntimePolicy.isVisible(
                isRunningOutput: true,
                showInactiveApps: false,
                hasCustomState: false
            )
        )
        XCTAssertFalse(
            MixerRuntimePolicy.isVisible(
                isRunningOutput: false,
                showInactiveApps: false,
                hasCustomState: false
            )
        )
        XCTAssertTrue(
            MixerRuntimePolicy.isVisible(
                isRunningOutput: false,
                showInactiveApps: true,
                hasCustomState: false
            )
        )
        XCTAssertTrue(
            MixerRuntimePolicy.isVisible(
                isRunningOutput: false,
                showInactiveApps: false,
                hasCustomState: true
            )
        )
    }
}

final class AppMixerStateTests: XCTestCase {
    func testDefaultState() {
        XCTAssertEqual(AppMixerState.default.volume, 1.0)
        XCTAssertFalse(AppMixerState.default.isMuted)
        XCTAssertNil(AppMixerState.default.outputDeviceUID)
    }

    func testCodableRoundTrip() throws {
        let original = AppMixerState(volume: 0.75, isMuted: true, outputDeviceUID: "uid")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppMixerState.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
