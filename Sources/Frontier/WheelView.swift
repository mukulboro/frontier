import SwiftUI
import FrontierCore

/// One slice of the wheel, with a small gap either side.
struct WheelSegment: Shape {
    let index: Int
    var gap: Double = 1.4

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let mid = WheelMath.centerAngle(of: index) - 90
        let a0 = Angle.degrees(mid - 22.5 + gap), a1 = Angle.degrees(mid + 22.5 - gap)
        var p = Path()
        p.addArc(center: c, radius: WheelModel.outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: WheelModel.inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        ZStack {
            Theme.void.opacity(0.80).ignoresSafeArea()
            RadialGradient(colors: [.clear, Theme.void.opacity(0.7)], center: .center, startRadius: 280, endRadius: 900)
                .ignoresSafeArea()
            wheel
            if model.editing {
                AppPicker(model: model)
                    .offset(x: WheelModel.outer + 210)
                    .transition(.opacity)
            }
            VStack {
                Spacer()
                HUDLabel(text: hint, size: 11, color: Theme.boneDim)
                    .padding(.bottom, 48)
            }
        }
        .animation(Theme.settle, value: model.editing)
    }

    private var hint: String {
        if model.editing { return "Choose an app to equip   ·   Esc to go back" }
        return (model.pinned ? "Click or ⏎ to draw" : "Release \(model.hotKeyLabel.split(separator: " ").first ?? "") to draw")
            + "   ·   E or right-click to change equipped   ·   Esc to holster"
    }

    private var wheel: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let on = model.selected == i
                WheelSegment(index: i)
                    .fill(on ? Theme.bone.opacity(0.16) : Theme.raised.opacity(0.72))
                WheelSegment(index: i)
                    .stroke(on ? Theme.gold : Theme.line, lineWidth: on ? 1.5 : 1)
                slot(i, on: on)
            }
            Circle().stroke(Theme.line, lineWidth: 1)
                .frame(width: WheelModel.inner * 2 - 10, height: WheelModel.inner * 2 - 10)
            hub.frame(width: WheelModel.inner * 2 - 34, height: WheelModel.inner * 2 - 34)
        }
        .frame(width: WheelModel.outer * 2 + 40, height: WheelModel.outer * 2 + 40)
        .animation(.easeOut(duration: 0.12), value: model.selected)
    }

    @ViewBuilder
    private func slot(_ i: Int, on: Bool) -> some View {
        let a = (WheelMath.centerAngle(of: i) - 90) * .pi / 180
        let r = (WheelModel.outer + WheelModel.inner) / 2
        Group {
            if let app = model.slots[i] {
                Image(nsImage: AppCatalog.icon(app.path))
                    .resizable().interpolation(.high)
                    .frame(width: 66, height: 66)
                    .saturation(on ? 1 : 0.55)
                    .opacity(on ? 1 : 0.8)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(on ? Theme.gold : Theme.boneFaint)
            }
        }
        .scaleEffect(on ? 1.14 : 1)
        .shadow(color: Theme.void.opacity(0.8), radius: 4, y: 2)
        .offset(x: cos(a) * r, y: sin(a) * r)
    }

    @ViewBuilder
    private var hub: some View {
        if let i = model.selected {
            if let m = model.meta {
                VStack(spacing: 5) {
                    Text(m.name.uppercased())
                        .font(Theme.display(21, .heavy)).tracking(2)
                        .foregroundStyle(Theme.bone)
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                    HStack(spacing: 6) {
                        Circle().fill(m.running ? Theme.gold : Theme.boneFaint).frame(width: 6, height: 6)
                        HUDLabel(text: m.running ? (m.hidden ? "Running · hidden" : "Running") : "Not running",
                                 size: 10, color: m.running ? Theme.gold : Theme.boneDim)
                    }
                    Rectangle().fill(Theme.line).frame(width: 70, height: 1).padding(.vertical, 2)
                    VStack(spacing: 2) {
                        if let c = m.category { meta(c) }
                        if let v = m.version { meta("Version \(v)") }
                        if let mem = m.memoryMB { meta(mem >= 1024 ? String(format: "%.1f GB in use", Double(mem) / 1024) : "\(mem) MB in use") }
                        if let d = m.launchedAt { meta("Up since \(d.formatted(date: .omitted, time: .shortened))") }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    HUDLabel(text: "Empty holster", size: 14, color: Theme.boneDim)
                    meta("Slot \(i + 1) · click to equip")
                }
            }
        } else {
            VStack(spacing: 8) {
                ArtGlyph(name: "hat", color: Theme.boneFaint).frame(width: 46, height: 46)
                HUDLabel(text: "Choose", size: 11, color: Theme.boneFaint)
            }
        }
    }

    private func meta(_ s: String) -> some View {
        Text(s).font(Theme.body(12.5)).foregroundStyle(Theme.boneDim).lineLimit(1).minimumScaleFactor(0.7)
    }
}

/// Searchable list of installed apps for re-equipping a slot.
struct AppPicker: View {
    @ObservedObject var model: WheelModel
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HUDLabel(text: "Equip slot \((model.selected ?? 0) + 1)", size: 13, color: Theme.gold)
            TextField("", text: $model.query, prompt: Text("Search apps").foregroundStyle(Theme.boneFaint))
                .textFieldStyle(.plain)
                .font(Theme.body(14))
                .foregroundStyle(Theme.bone)
                .focused($searching)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.void.opacity(0.6))
                .overlay(Rectangle().stroke(searching ? Theme.gold : Theme.line, lineWidth: 1))
                .onSubmit { if let first = model.filtered.first, let i = model.selected { model.onEquip?(i, first) } }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filtered) { app in
                        Button {
                            if let i = model.selected { model.onEquip?(i, app) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: AppCatalog.icon(app.path)).resizable().frame(width: 26, height: 26)
                                Text(app.name).font(Theme.body(14)).foregroundStyle(Theme.bone).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 5).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
                    }
                }
            }
            Button {
                if let i = model.selected { model.onEquip?(i, nil) }
            } label: {
                HUDLabel(text: "Leave slot empty", size: 11, color: Theme.rustLight)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 300, height: 430)
        .background(Theme.surface.opacity(0.96))
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .onAppear { searching = true }
    }
}
