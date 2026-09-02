import Foundation

/// Filter types for the equalizer biquads.
enum EqualizerFilterType: String, Codable, CaseIterable, Equatable {
    case lowShelf
    case peaking
    case highShelf

    var displayName: String {
        switch self {
        case .lowShelf: return "Prateleira Grave (Low Shelf)"
        case .peaking: return "Pico (Peaking)"
        case .highShelf: return "Prateleira Aguda (High Shelf)"
        }
    }

    var rtFilterType: RTEQFilterType {
        switch self {
        case .lowShelf: return RT_EQ_FILTER_LOW_SHELF
        case .peaking: return RT_EQ_FILTER_PEAKING
        case .highShelf: return RT_EQ_FILTER_HIGH_SHELF
        }
    }
}

/// One band in the parametric/graphic equalizer.
struct EqualizerBand: Codable, Equatable, Identifiable {
    var id: Int { index }
    let index: Int
    var frequency: Double // Hz
    var gain: Double      // dB (-12.0 ... +12.0)
    var q: Double         // Quality factor / bandwidth (0.3 ... 10.0)
    var type: EqualizerFilterType

    var formattedFrequency: String {
        if frequency >= 1000 {
            let khz = frequency / 1000.0
            return khz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(khz))k" : String(format: "%.1fk", khz)
        } else {
            return "\(Int(frequency))"
        }
    }

    var formattedGain: String {
        let sign = gain > 0 ? "+" : ""
        return String(format: "%@%.1f dB", sign, gain)
    }

    var formattedQ: String {
        String(format: "Q: %.2f", q)
    }

    var rtBand: RTEQBand {
        RTEQBand(
            frequency: frequency,
            gainDb: gain,
            q: q,
            type: type.rtFilterType
        )
    }
}

/// Predefined equalizer curve presets.
struct EqualizerPreset: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let bands: [EqualizerBand]

    static let standardFrequencies: [Double] = [
        32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    static func makeBands(gains: [Double], qs: [Double]? = nil) -> [EqualizerBand] {
        let defaultQs: [Double] = [0.707, 1.414, 1.414, 1.414, 1.414, 1.414, 1.414, 1.414, 1.414, 0.707]
        let effectiveQs = qs ?? defaultQs

        return standardFrequencies.enumerated().map { index, freq in
            let type: EqualizerFilterType
            if index == 0 {
                type = .lowShelf
            } else if index == standardFrequencies.count - 1 {
                type = .highShelf
            } else {
                type = .peaking
            }
            let gain = index < gains.count ? gains[index] : 0.0
            let q = index < effectiveQs.count ? effectiveQs[index] : 1.414
            return EqualizerBand(
                index: index,
                frequency: freq,
                gain: gain,
                q: q,
                type: type
            )
        }
    }

    static let flat = EqualizerPreset(
        name: "Neutro (Flat)",
        bands: makeBands(gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    )

    static let bassBooster = EqualizerPreset(
        name: "Reforço de Graves",
        bands: makeBands(gains: [6.0, 5.0, 3.5, 1.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    )

    static let bassReducer = EqualizerPreset(
        name: "Redutor de Graves",
        bands: makeBands(gains: [-6.0, -5.0, -3.5, -1.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    )

    static let trebleBooster = EqualizerPreset(
        name: "Reforço de Agudos",
        bands: makeBands(gains: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.5, 3.5, 5.0, 6.0])
    )

    static let trebleReducer = EqualizerPreset(
        name: "Redutor de Agudos",
        bands: makeBands(gains: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.5, -3.5, -5.0, -6.0])
    )

    static let vocalBooster = EqualizerPreset(
        name: "Voz / Podcast",
        bands: makeBands(gains: [-2.0, -1.0, 0.0, 1.5, 3.0, 4.0, 3.0, 1.0, 0.0, -1.0])
    )

    static let rock = EqualizerPreset(
        name: "Rock",
        bands: makeBands(gains: [4.5, 3.5, 1.5, 0.0, -1.0, 0.5, 2.0, 3.5, 4.5, 4.0])
    )

    static let pop = EqualizerPreset(
        name: "Pop",
        bands: makeBands(gains: [1.5, 2.5, 3.0, 1.0, 0.0, 1.5, 2.5, 2.0, 1.5, 1.0])
    )

    static let electronic = EqualizerPreset(
        name: "Eletrônica / Dance",
        bands: makeBands(gains: [5.5, 5.0, 2.5, 0.0, -1.5, 1.5, 2.0, 3.5, 4.5, 4.0])
    )

    static let acoustic = EqualizerPreset(
        name: "Acústico / Clássica",
        bands: makeBands(gains: [2.0, 2.0, 1.0, 0.5, 1.0, 1.5, 2.0, 2.5, 2.0, 1.5])
    )

    static let loudness = EqualizerPreset(
        name: "Loudness",
        bands: makeBands(gains: [5.0, 4.0, 1.5, 0.0, -1.0, 0.0, 1.0, 2.5, 4.0, 4.5])
    )

    static let customName = "Personalizado"

    static let allPresets: [EqualizerPreset] = [
        flat,
        bassBooster,
        bassReducer,
        trebleBooster,
        trebleReducer,
        vocalBooster,
        rock,
        pop,
        electronic,
        acoustic,
        loudness
    ]

    static func matchingPreset(for bands: [EqualizerBand]) -> EqualizerPreset? {
        allPresets.first { preset in
            guard preset.bands.count == bands.count else { return false }
            for i in 0..<bands.count {
                if abs(preset.bands[i].gain - bands[i].gain) > 0.05 ||
                    abs(preset.bands[i].q - bands[i].q) > 0.05 {
                    return false
                }
            }
            return true
        }
    }
}

/// Overall configuration for the master equalizer and limiter.
struct EqualizerConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var presetName: String
    var bands: [EqualizerBand]
    var isLimiterEnabled: Bool
    var limiterThresholdDb: Float
    var limiterReleaseMs: Float

    static let `default` = EqualizerConfiguration(
        isEnabled: false,
        presetName: EqualizerPreset.flat.name,
        bands: EqualizerPreset.flat.bands,
        isLimiterEnabled: true,
        limiterThresholdDb: -0.1,
        limiterReleaseMs: 80.0
    )
}
