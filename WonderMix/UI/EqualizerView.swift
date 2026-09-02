import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject private var controller: MixerController
    @State private var selectedBandIndex: Int = 1 // Default to 64 Hz (Bass)
    @State private var showsAdvancedSettings: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Master switch & Preset selector
            topBar

            // Real-time EQ curve visualizer
            EqualizerCurveView(bands: controller.equalizerConfig.bands, isEnabled: controller.equalizerConfig.isEnabled)
                .frame(height: 60)
                .background(WonderMixTheme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // 10-Band Graphic Sliders
            bandsView
                .padding(.vertical, 4)

            // Band Inspector: Q Factor & Fine Tuning
            bandInspectorCard

            // Output Limiter / Anti-Clipping Stage
            limiterCard
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .tint(WonderMixTheme.ink)
        .foregroundStyle(WonderMixTheme.ink)
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack(spacing: 10) {
            // Preset Menu
            Menu {
                ForEach(EqualizerPreset.allPresets) { preset in
                    Button {
                        controller.setEqualizerPreset(preset)
                    } label: {
                        HStack {
                            Text(preset.name)
                            if controller.equalizerConfig.presetName == preset.name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 11, weight: .semibold))
                    Text(controller.equalizerConfig.presetName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(WonderMixTheme.inkMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(WonderMixTheme.fill, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Zerar") {
                controller.resetEqualizer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(WonderMixTheme.inkMuted)
            .help("Redefinir todas as bandas para 0 dB")

            Toggle("Equalizador ativo", isOn: Binding(
                get: { controller.equalizerConfig.isEnabled },
                set: { controller.setEqualizerEnabled($0) }
            ))
            .toggleStyle(WhiteSwitchStyle())
            .labelsHidden()
            .help(controller.equalizerConfig.isEnabled ? "Desativar equalizador" : "Ativar equalizador")
        }
    }

    private var bandsView: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(controller.equalizerConfig.bands) { band in
                bandColumn(for: band)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(WonderMixTheme.fill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func bandColumn(for band: EqualizerBand) -> some View {
        let isSelected = selectedBandIndex == band.index
        let isEQActive = controller.equalizerConfig.isEnabled

        return VStack(spacing: 4) {
            // Gain text readout
            Text(gainText(for: band.gain))
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(gainColor(for: band.gain, isEnabled: isEQActive))
                .frame(height: 12)

            // Vertical Slider
            WhiteVerticalSlider(
                value: Binding(
                    get: { band.gain },
                    set: { controller.setBandGain(index: band.index, gain: $0) }
                ),
                range: -12.0...12.0,
                isEnabled: isEQActive
            )
            .frame(height: 100)
            .opacity(isEQActive ? 1.0 : 0.45)

            // Frequency label
            Text(band.formattedFrequency)
                .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? WonderMixTheme.ink : WonderMixTheme.inkMuted)

            // Band type indicator dot
            Circle()
                .fill(isSelected ? WonderMixTheme.ink : (band.type == .peaking ? WonderMixTheme.inkFaint : WonderMixTheme.glow))
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? WonderMixTheme.fill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedBandIndex = band.index
        }
    }

    private var bandInspectorCard: some View {
        let band = inspectedBand
        let isEQActive = controller.equalizerConfig.isEnabled

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(band.formattedFrequency + " Hz")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(WonderMixTheme.ink)

                        Text(band.type.displayName)
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(WonderMixTheme.fill, in: Capsule())
                            .foregroundStyle(WonderMixTheme.inkMuted)
                    }

                    Text("Ganho: \(band.formattedGain)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WonderMixTheme.inkMuted)
                }

                Spacer()

                // Q value description badge
                VStack(alignment: .trailing, spacing: 2) {
                    Text(band.formattedQ)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(WonderMixTheme.ink)
                    Text(qDescription(for: band.q))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(WonderMixTheme.glow)
                }
            }

            // Q factor slider
            HStack(spacing: 8) {
                Text("Q:")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WonderMixTheme.inkMuted)

                WhiteVolumeSlider(
                    value: Binding(
                        get: { inspectedBand.q },
                        set: { controller.setBandQ(index: selectedBandIndex, q: $0) }
                    ),
                    range: 0.3...5.0,
                    isEnabled: isEQActive
                )

                Button {
                    controller.setBandQ(index: selectedBandIndex, q: 1.414)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(WonderMixTheme.inkFaint)
                }
                .buttonStyle(.plain)
                .help("Restaurar Q padrão (1.41)")
            }
        }
        .padding(10)
        .background(WonderMixTheme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var limiterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: controller.equalizerConfig.isLimiterEnabled ? "shield.fill" : "shield.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(controller.equalizerConfig.isLimiterEnabled ? WonderMixTheme.glow : WonderMixTheme.inkFaint)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Limitador de Saída (Anti-Clipping)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(WonderMixTheme.ink)
                    Text("Evita distorções ao impulsionar graves e protege alto-falantes.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(WonderMixTheme.inkMuted)
                }

                Spacer(minLength: 4)

                Toggle("Limitador ativo", isOn: Binding(
                    get: { controller.equalizerConfig.isLimiterEnabled },
                    set: { controller.setLimiterEnabled($0) }
                ))
                .toggleStyle(WhiteSwitchStyle())
                .labelsHidden()
            }
        }
        .padding(10)
        .background(WonderMixTheme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Helpers

    private var inspectedBand: EqualizerBand {
        let bands = controller.equalizerConfig.bands
        guard selectedBandIndex >= 0 && selectedBandIndex < bands.count else {
            return bands.first ?? EqualizerBand(index: 0, frequency: 32, gain: 0, q: 0.707, type: .lowShelf)
        }
        return bands[selectedBandIndex]
    }

    private func gainText(for gain: Double) -> String {
        if abs(gain) < 0.1 {
            return "0"
        }
        let sign = gain > 0 ? "+" : ""
        return String(format: "%@%.0f", sign, gain)
    }

    private func gainColor(for gain: Double, isEnabled: Bool) -> Color {
        guard isEnabled else { return WonderMixTheme.inkFaint }
        if gain > 0.5 {
            return WonderMixTheme.glow
        } else if gain < -0.5 {
            return WonderMixTheme.inkMuted
        } else {
            return WonderMixTheme.inkFaint
        }
    }

    private func qDescription(for q: Double) -> String {
        if q < 0.7 {
            return "Amplo / Musical"
        } else if q <= 1.8 {
            return "Equilibrado"
        } else {
            return "Estreito / Cirúrgico"
        }
    }
}

/// Dynamic Bézier curve showing the frequency response across all bands.
struct EqualizerCurveView: View {
    let bands: [EqualizerBand]
    let isEnabled: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let midY = height * 0.5

            ZStack {
                // 0 dB reference line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: width, y: midY))
                }
                .stroke(WonderMixTheme.inkFaint.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // Gain curve
                curvePath(width: width, height: height, midY: midY)
                    .stroke(
                        isEnabled ? WonderMixTheme.glow : WonderMixTheme.inkMuted,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                // Subtle gradient under the curve
                curveAreaPath(width: width, height: height, midY: midY)
                    .fill(
                        LinearGradient(
                            colors: [
                                (isEnabled ? WonderMixTheme.glow : WonderMixTheme.ink).opacity(0.22),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .padding(.horizontal, 10)
    }

    private func curvePath(width: CGFloat, height: CGFloat, midY: CGFloat) -> Path {
        var path = Path()
        guard !bands.isEmpty else { return path }

        let points = samplePoints(width: width, height: height, midY: midY)
        guard let first = points.first else { return path }
        path.move(to: first)

        for i in 1..<points.count {
            let p0 = points[i - 1]
            let p1 = points[i]
            let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            path.addQuadCurve(to: mid, control: p0)
        }
        if let last = points.last {
            path.addLine(to: last)
        }

        return path
    }

    private func curveAreaPath(width: CGFloat, height: CGFloat, midY: CGFloat) -> Path {
        var path = curvePath(width: width, height: height, midY: midY)
        path.addLine(to: CGPoint(x: width, y: midY))
        path.addLine(to: CGPoint(x: 0, y: midY))
        path.closeSubpath()
        return path
    }

    private func samplePoints(width: CGFloat, height: CGFloat, midY: CGFloat) -> [CGPoint] {
        let step = max(Int(width / 32), 1)
        var points: [CGPoint] = []

        for x in stride(from: 0, through: Int(width), by: step) {
            let normX = CGFloat(x) / width
            // Map normX logarithmically to frequency range 20Hz - 20000Hz
            let freq = 20.0 * pow(1000.0, Double(normX))

            // Approximate cumulative gain response from all biquad bands
            var totalGainDb = 0.0
            for band in bands {
                let octDistance = log2(freq / band.frequency)
                let bw = 1.0 / max(band.q, 0.2)
                let weight = exp(-0.5 * pow(octDistance / (bw * 0.5), 2.0))
                totalGainDb += band.gain * weight
            }

            // Clamp gain to -12 ... +12 dB
            let clampedDb = min(max(totalGainDb, -12.0), 12.0)
            let y = midY - CGFloat(clampedDb / 12.0) * (height * 0.42)
            points.append(CGPoint(x: CGFloat(x), y: y))
        }

        return points
    }
}
