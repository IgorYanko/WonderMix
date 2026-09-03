import AppKit
import SwiftUI

enum WonderMixTheme {
    static let orange = Color(red: 1.00, green: 0.45, blue: 0.12)
    static let orangeDeep = Color(red: 0.92, green: 0.28, blue: 0.04)
    static let glow = Color(red: 1.00, green: 0.78, blue: 0.42)
    static let ink = Color.white
    static let inkMuted = Color.white.opacity(0.78)
    static let inkFaint = Color.white.opacity(0.52)
    static let hairline = Color.white.opacity(0.22)
    static let fill = Color.white.opacity(0.14)
}

struct OrangeBlurBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WonderMixTheme.orange, WonderMixTheme.orangeDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(WonderMixTheme.glow.opacity(0.55))
                .frame(width: 260, height: 260)
                .blur(radius: 54)
                .offset(x: 110, y: -90)

            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 180, height: 180)
                .blur(radius: 42)
                .offset(x: -90, y: 40)

            Circle()
                .fill(WonderMixTheme.orange.opacity(0.7))
                .frame(width: 280, height: 280)
                .blur(radius: 64)
                .offset(x: -40, y: 220)
        }
        .ignoresSafeArea()
    }
}

/// Clears the default menu-bar window material so the orange fill is what you see.
struct ClearPopoverWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.apply(to: nsView.window)
        }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        hideVisualEffects(in: window.contentView)
        hideVisualEffects(in: window.contentView?.superview)
    }

    private static func hideVisualEffects(in root: NSView?) {
        guard let root else { return }
        var stack = [root]
        while let view = stack.popLast() {
            if view is NSVisualEffectView {
                view.isHidden = true
            }
            stack.append(contentsOf: view.subviews)
        }
    }
}

struct WhiteProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(WonderMixTheme.orangeDeep)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(WonderMixTheme.ink.opacity(configuration.isPressed ? 0.82 : 1), in: Capsule())
    }
}

struct WhiteSwitchStyle: ToggleStyle {
    var stretch: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                configuration.label
                if stretch {
                    Spacer(minLength: 8)
                }
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .strokeBorder(WonderMixTheme.ink.opacity(configuration.isOn ? 1 : 0.45), lineWidth: 1.5)
                        .background(Capsule().fill(configuration.isOn ? WonderMixTheme.ink.opacity(0.28) : Color.clear))
                    Circle()
                        .fill(WonderMixTheme.ink)
                        .padding(2)
                }
                .frame(width: 34, height: 20)
            }
        }
        .buttonStyle(.plain)
    }
}

struct WhiteVolumeSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1.5
    var isEnabled: Bool = true

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 14
            let trackHeight: CGFloat = 4
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let clamped = min(max(fraction, 0), 1)
            let travel = max(geo.size.width - knob, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WonderMixTheme.fill)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(WonderMixTheme.ink)
                    .frame(width: knob + travel * clamped, height: trackHeight)

                Circle()
                    .fill(WonderMixTheme.ink)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .offset(x: travel * clamped)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        let x = min(max(drag.location.x - knob / 2, 0), travel)
                        let next = travel == 0 ? range.lowerBound : range.lowerBound + Double(x / travel) * (range.upperBound - range.lowerBound)
                        value = next
                    }
            )
        }
        .frame(height: 18)
        .allowsHitTesting(isEnabled)
        .accessibilityValue(Text("\(Int((value * 100).rounded()))%"))
    }
}
