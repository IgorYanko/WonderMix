import XCTest
@testable import WonderMix

@MainActor
final class EqualizerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: MixerPreferences!

    override func setUp() {
        super.setUp()
        suiteName = "WonderMixEqualizerTests.\(UUID().uuidString)"
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

    // MARK: - Model & Presets Tests

    func testStandard10BandFrequenciesAndTypes() {
        let bands = EqualizerPreset.flat.bands
        XCTAssertEqual(bands.count, 10)

        let expectedFrequencies = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0]
        for (i, expectedFreq) in expectedFrequencies.enumerated() {
            XCTAssertEqual(bands[i].frequency, expectedFreq)
        }

        XCTAssertEqual(bands.first?.type, .lowShelf)
        XCTAssertEqual(bands.last?.type, .highShelf)
        for i in 1...8 {
            XCTAssertEqual(bands[i].type, .peaking)
        }
    }

    func testFormattedFrequenciesAndGains() {
        let bands = EqualizerPreset.flat.bands
        XCTAssertEqual(bands[0].formattedFrequency, "32")
        XCTAssertEqual(bands[5].formattedFrequency, "1k")
        XCTAssertEqual(bands[9].formattedFrequency, "16k")

        var testBand = bands[0]
        testBand.gain = 4.5
        XCTAssertEqual(testBand.formattedGain, "+4.5 dB")

        testBand.gain = -3.0
        XCTAssertEqual(testBand.formattedGain, "-3.0 dB")

        testBand.q = 1.414
        XCTAssertEqual(testBand.formattedQ, "Q: 1.41")
    }

    func testPresetProperties() {
        let flat = EqualizerPreset.flat
        XCTAssertTrue(flat.bands.allSatisfy { $0.gain == 0.0 })

        let bassBooster = EqualizerPreset.bassBooster
        XCTAssertGreaterThan(bassBooster.bands[0].gain, 0.0)
        XCTAssertGreaterThan(bassBooster.bands[1].gain, 0.0)
        XCTAssertEqual(bassBooster.bands[9].gain, 0.0)

        let trebleBooster = EqualizerPreset.trebleBooster
        XCTAssertEqual(trebleBooster.bands[0].gain, 0.0)
        XCTAssertGreaterThan(trebleBooster.bands[9].gain, 0.0)

        let matching = EqualizerPreset.matchingPreset(for: bassBooster.bands)
        XCTAssertEqual(matching?.name, bassBooster.name)

        var modified = bassBooster.bands
        modified[0].gain = 11.5
        XCTAssertNil(EqualizerPreset.matchingPreset(for: modified))
    }

    // MARK: - Preferences Persistence Tests

    func testEqualizerPreferencesDefault() {
        let config = preferences.equalizerConfig
        XCTAssertFalse(config.isEnabled)
        XCTAssertTrue(config.isLimiterEnabled)
        XCTAssertEqual(config.presetName, EqualizerPreset.flat.name)
        XCTAssertEqual(config.bands.count, 10)
    }

    func testEqualizerPreferencesPersistenceAcrossInstances() {
        var customConfig = EqualizerConfiguration.default
        customConfig.isEnabled = true
        customConfig.presetName = EqualizerPreset.bassBooster.name
        customConfig.bands = EqualizerPreset.bassBooster.bands
        customConfig.isLimiterEnabled = true
        customConfig.limiterThresholdDb = -0.5

        preferences.equalizerConfig = customConfig

        let reloadedPrefs = MixerPreferences(defaults: defaults)
        let loadedConfig = reloadedPrefs.equalizerConfig

        XCTAssertTrue(loadedConfig.isEnabled)
        XCTAssertTrue(loadedConfig.isLimiterEnabled)
        XCTAssertEqual(loadedConfig.presetName, EqualizerPreset.bassBooster.name)
        XCTAssertEqual(loadedConfig.bands[0].gain, 6.0)
        XCTAssertEqual(loadedConfig.limiterThresholdDb, -0.5)
    }

    func testResetEqualizerRestoresDefaults() {
        var modified = preferences.equalizerConfig
        modified.isEnabled = true
        modified.bands[0].gain = 8.0
        preferences.equalizerConfig = modified

        XCTAssertTrue(preferences.equalizerConfig.isEnabled)

        preferences.resetEqualizer()

        let resetConfig = preferences.equalizerConfig
        XCTAssertFalse(resetConfig.isEnabled)
        XCTAssertEqual(resetConfig.bands[0].gain, 0.0)
        XCTAssertEqual(resetConfig.presetName, EqualizerPreset.flat.name)
    }

    // MARK: - RT Band Conversion Tests

    func testRTBandConversion() {
        let band = EqualizerBand(
            index: 2,
            frequency: 125.0,
            gain: 3.5,
            q: 1.2,
            type: .peaking
        )
        let rt = band.rtBand
        XCTAssertEqual(rt.frequency, 125.0)
        XCTAssertEqual(rt.gainDb, 3.5)
        XCTAssertEqual(rt.q, 1.2)
        XCTAssertEqual(rt.type, RT_EQ_FILTER_PEAKING)
    }

    func testAllPresetsIntegrity() {
        for preset in EqualizerPreset.allPresets {
            XCTAssertEqual(preset.bands.count, 10, "Preset \(preset.name) must have exactly 10 bands")
            for band in preset.bands {
                XCTAssertGreaterThanOrEqual(band.gain, -12.0)
                XCTAssertLessThanOrEqual(band.gain, 12.0)
                XCTAssertGreaterThanOrEqual(band.q, 0.2)
                XCTAssertLessThanOrEqual(band.q, 10.0)
                XCTAssertGreaterThanOrEqual(band.frequency, 20.0)
                XCTAssertLessThanOrEqual(band.frequency, 20000.0)
            }
        }
    }

    func testMixerControllerEqualizerActions() {
        let controller = MixerController.shared
        controller.resetEqualizer()

        XCTAssertFalse(controller.equalizerConfig.isEnabled)
        XCTAssertEqual(controller.equalizerConfig.presetName, EqualizerPreset.flat.name)

        controller.setEqualizerEnabled(true)
        XCTAssertTrue(controller.equalizerConfig.isEnabled)

        controller.setEqualizerPreset(.rock)
        XCTAssertEqual(controller.equalizerConfig.presetName, EqualizerPreset.rock.name)
        XCTAssertEqual(controller.equalizerConfig.bands[0].gain, 4.5)

        controller.setBandGain(index: 0, gain: 8.5)
        XCTAssertEqual(controller.equalizerConfig.bands[0].gain, 8.5)
        XCTAssertEqual(controller.equalizerConfig.presetName, EqualizerPreset.customName)

        controller.setBandQ(index: 0, q: 2.5)
        XCTAssertEqual(controller.equalizerConfig.bands[0].q, 2.5)

        controller.setLimiterEnabled(false)
        XCTAssertFalse(controller.equalizerConfig.isLimiterEnabled)

        controller.setLimiterThreshold(db: -0.8)
        XCTAssertEqual(controller.equalizerConfig.limiterThresholdDb, -0.8)

        controller.resetEqualizer()
        XCTAssertFalse(controller.equalizerConfig.isEnabled)
        XCTAssertEqual(controller.equalizerConfig.presetName, EqualizerPreset.flat.name)
    }
}

