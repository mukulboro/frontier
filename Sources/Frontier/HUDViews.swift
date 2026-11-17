import SwiftUI
import FrontierCore

/// Reports pointer entry/exit even when the app isn't active — the HUD lives on the desktop,
/// where SwiftUI's own hover tracking doesn't fire.
struct HoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> SensorView { SensorView(onChange: onChange) }
    func updateNSView(_ view: SensorView, context: Context) { view.onChange = onChange }

    final class SensorView: NSView {
        var onChange: (Bool) -> Void
        private var area: NSTrackingArea?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(a)
            area = a
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}

/// One "core": the ring is the fast reading, the glyph fill is its slow average.
/// Hovering swaps the name for the actual number.
struct CoreRing: View {
    let symbol: String
    let label: String
    /// Fast-moving ring, 0…1.
    let bar: Double
    /// Slow-moving inner core, 0…1.
    let core: Double
    /// The real reading, shown on hover.
    var detail: String?
    var fortified = false
    var size: CGFloat = 46
    /// Lets snapshots render the hovered state.
    var forceHover = false
    @State private var hovering = false

    private var depleted: Bool { bar < 0.25 }
    private var tint: Color { depleted ? Theme.rustLight : Theme.bone }
    private var showDetail: Bool { (hovering || forceHover) && detail != nil }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                // Depletion is signalled by shape (dashed track), not colour alone.
                Circle()
                    .stroke(Theme.bone.opacity(0.18), style: StrokeStyle(lineWidth: 3, dash: depleted ? [4, 3] : []))
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, bar)))
                    .stroke(fortified ? Theme.gold : tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if fortified {
                    Circle().stroke(Theme.gold.opacity(0.9), lineWidth: 1).padding(-4)
                }
                glyph.foregroundStyle(tint.opacity(0.22))
                glyph.foregroundStyle(fortified ? Theme.gold : tint)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: size * 0.5 * max(0, min(1, core)))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
            }
            .frame(width: size, height: size)
            .shadow(color: fortified ? Theme.gold.opacity(0.5) : .clear, radius: 5)
            HUDLabel(text: showDetail ? (detail ?? label) : label, size: showDetail ? 10.5 : 9.5,
                     color: showDetail ? Theme.bone : Theme.bone.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
                .frame(width: size + 22, height: 14)
        }
        .shadow(color: Theme.void.opacity(0.85), radius: 2, y: 1)
        .background(HoverSensor { hovering = $0 })
        .animation(.easeOut(duration: 0.14), value: showDetail)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue((detail ?? "\(Int(bar * 100)) percent") + (depleted ? ", low" : ""))
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size * 0.5, height: size * 0.5)
    }
}

struct CoresView: View {
    @ObservedObject var state: AppState
    var forceHover = false

    var body: some View {
        if let v = state.vitals {
            HStack(spacing: 0) {
                if let b = v.battery {
                    CoreRing(symbol: "bolt.fill", label: "Battery", bar: b, core: state.slowBattery.value ?? b,
                             detail: v.batteryText, fortified: v.charging, forceHover: forceHover)
                }
                if let w = v.wifi {
                    CoreRing(symbol: "wifi", label: "Signal", bar: w, core: state.slowWifi.value ?? w,
                             detail: v.wifiText, forceHover: forceHover)
                }
                CoreRing(symbol: "memorychip.fill", label: "Memory", bar: v.ramFree, core: state.slowRAM.value ?? v.ramFree,
                         detail: v.ramText, forceHover: forceHover)
                CoreRing(symbol: "cpu.fill", label: "CPU", bar: v.cpuFree, core: state.slowCPU.value ?? v.cpuFree,
                         detail: v.cpuText, forceHover: forceHover)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }
}

/// The honor bar: a hat that glides between red (left) and white (right). No numbers, ever.
struct HonorMeter: View {
    let honor: Double
    let rank: HonorRank
    var onPaper = false
    var width: CGFloat = 320

    private var positive: Color { onPaper ? Theme.ink : Theme.bone }
    private var negative: Color { onPaper ? Theme.rustDark : Theme.rustLight }
    private var markerColor: Color { honor < -0.10 ? negative : positive }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: [negative, positive.opacity(0.35), positive], startPoint: .leading, endPoint: .trailing))
                    .opacity(onPaper ? 0.55 : 0.5)
                    .frame(height: 4)
                Rectangle().fill(positive.opacity(0.55)).frame(width: 1, height: 10)
                ArtGlyph(name: "hat", color: markerColor)
                    .frame(width: 26, height: 26)
                    .offset(x: CGFloat(max(-1, min(1, honor))) * (width / 2 - 13), y: -1)
                    .animation(Theme.honorGlide, value: honor)
            }
            .frame(width: width, height: 26)
            HUDLabel(text: rank.rawValue, size: 11, color: onPaper ? Theme.inkSoft : Theme.bone.opacity(0.9))
        }
        .shadow(color: onPaper ? .clear : Theme.void.opacity(0.85), radius: 2, y: 1)
        .accessibilityElement()
        .accessibilityLabel("Honor: \(rank.rawValue.capitalized)")
    }
}

struct HonorToastView: View {
    let toast: HonorToast

    var body: some View {
        HStack(spacing: 8) {
            ArtGlyph(name: "hat", color: toast.gained ? Theme.bone : Theme.rustLight).frame(width: 18, height: 18)
            HUDLabel(text: toast.gained ? "Honor gained" : "Honor lost", size: 12,
                     color: toast.gained ? Theme.bone : Theme.rustLight)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.void.opacity(0.78), in: RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.line, lineWidth: 1))
    }
}

/// The honor meter and its toasts, bottom-centre of the desktop. Click-through.
struct HonorHUDView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            if let t = state.toast {
                HonorToastView(toast: t).transition(.opacity)
            }
            HonorMeter(honor: state.ledger.honor, rank: state.rank)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.3), value: state.toast)
        .padding(.bottom, 22)
    }
}
