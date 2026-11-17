import SwiftUI
import ServiceManagement
import FrontierCore

enum PopoverTab: String, CaseIterable { case camp = "Camp", ledger = "Ledger", wheel = "Wheel", tally = "Tally", settings = "Settings" }

struct PopoverView: View {
    @ObservedObject var state: AppState
    @State var tab: PopoverTab = .camp
    var onOpenWheel: () -> Void = {}
    var onHotKeyChange: () -> Bool = { true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch tab {
                case .camp: CampTab(state: state)
                case .ledger: LedgerTab(state: state)
                case .wheel: WheelTab(state: state, onOpenWheel: onOpenWheel)
                case .tally: TallyTab(state: state)
                case .settings: SettingsTab(state: state, onHotKeyChange: onHotKeyChange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 380, height: 560)
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .tint(Theme.ochre)
        .environment(\.colorScheme, .light)   // parchment is a light surface whatever the system theme
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Frontier").font(Theme.western(24)).foregroundStyle(Theme.ink)
                Spacer()
                HUDLabel(text: state.rank.rawValue, size: 10.5, color: state.ledger.honor < -0.1 ? Theme.rustDark : Theme.inkSoft)
            }
            HStack(spacing: 0) {
                ForEach(PopoverTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 5) {
                            HUDLabel(text: t.rawValue, size: 10.5, color: tab == t ? Theme.ink : Theme.inkFaint)
                            Rectangle().fill(tab == t ? Theme.rustDark : .clear).frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 16)
        .background(Theme.paperHi.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.paperEdge.opacity(0.6)).frame(height: 1) }
    }
}

// MARK: Shared pieces

struct InkButton: View {
    let title: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDLabel(text: title, size: 12, color: prominent ? Theme.paperHi : (destructive ? Theme.rustDark : Theme.ink))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(minWidth: 64)
                .background(prominent ? Theme.ink : .clear)
                .overlay(Rectangle().stroke(destructive ? Theme.rustDark : Theme.ink, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SectionRule: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            HUDLabel(text: title, size: 10.5, color: Theme.inkSoft)
            Rectangle().fill(Theme.paperEdge.opacity(0.7)).frame(height: 1)
        }
    }
}

struct PaperToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body(14))
                if let detail { Text(detail).font(Theme.body(11.5)).foregroundStyle(Theme.inkSoft) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(InkToggleStyle())
    }
}

/// A switch drawn in ink, so it reads the same whether or not the popover is the key window.
struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Theme.ink : .clear)
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 1.2))
                    .frame(width: 34, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? Theme.paperHi : Theme.ink).frame(width: 12, height: 12).padding(.horizontal, 3)
                    }
                    .animation(Theme.settle, value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: Camp (timer)

struct CampTab: View {
    @ObservedObject var state: AppState

    private var p: PomodoroEngine { state.pomodoro }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                HUDLabel(text: phaseTitle, size: 12, color: Theme.inkSoft)
                Text(p.phase.isActive ? formatClock(p.remaining(now: state.now)) : formatClock(Double(state.settings.pomodoro.focusMinutes * 60)))
                    .font(Theme.display(76, .heavy))
                    .monospacedDigit()
                    .foregroundStyle(p.phase.isBreak ? Theme.ochre : Theme.ink)
                HStack(spacing: 6) {
                    ForEach(1...max(1, state.settings.pomodoro.rounds), id: \.self) { r in
                        Circle()
                            .fill(roundDone(r) ? Theme.ink : .clear)
                            .overlay(Circle().stroke(r == p.round && p.phase.isActive ? Theme.rustDark : Theme.inkFaint, lineWidth: 1.2))
                            .frame(width: 8, height: 8)
                    }
                }
                .accessibilityLabel("Round \(p.round) of \(state.settings.pomodoro.rounds)")
            }
            .padding(.top, 14)

            HStack(spacing: 10) {
                if p.phase.isActive {
                    InkButton(title: p.isPaused ? "Resume" : "Pause", prominent: true) { state.togglePause() }
                    InkButton(title: "Skip") { state.skipPhase() }
                    InkButton(title: "Douse", destructive: true) { state.resetTimer() }
                } else {
                    InkButton(title: "Light the fire", prominent: true) { state.startTimer() }
                }
            }

            VStack(spacing: 8) {
                SectionRule(title: "Lengths")
                stepper("Focus", value: $state.settings.pomodoro.focusMinutes, range: 1...180, unit: "min")
                stepper("Short rest", value: $state.settings.pomodoro.shortBreakMinutes, range: 1...60, unit: "min")
                stepper("Long rest", value: $state.settings.pomodoro.longBreakMinutes, range: 1...120, unit: "min")
                stepper("Rounds", value: $state.settings.pomodoro.rounds, range: 1...12, unit: "")
            }
            .disabled(p.phase.isActive)
            .opacity(p.phase.isActive ? 0.5 : 1)

            VStack(spacing: 8) {
                SectionRule(title: "Campfire")
                PaperToggle(title: "Fire on the desktop", isOn: $state.settings.campfireOnDesktop)
                if p.phase != .idle, state.settings.campfireOnDesktop {
                    InkButton(title: "Sit by the fire") { state.immersive = true }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            CampProgress(renown: state.ledger.renown)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private var phaseTitle: String {
        if p.isPaused { return "Paused" }
        switch p.phase {
        case .idle: return "Ready"
        case .focus: return "Focus · Round \(p.round)"
        case .shortBreak: return "Rest a while"
        case .longBreak: return "Long rest"
        case .done: return "The fire is out"
        }
    }

    private func roundDone(_ r: Int) -> Bool {
        p.phase == .done || (p.phase.isActive && (r < p.round || (r == p.round && p.phase.isBreak)))
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title).font(Theme.body(14))
                Spacer()
                Text(unit.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(unit)")
                    .font(Theme.body(14, .semibold)).monospacedDigit()
            }
        }
        .controlSize(.small)
    }
}

/// What the camp has earned so far, and how close the next piece is. No numbers: a bar, like honor.
struct CampProgress: View {
    let renown: Double

    var body: some View {
        let unlocked = CampUpgrade.unlocked(renown: renown)
        VStack(spacing: 7) {
            SectionRule(title: "The camp")
            HStack(spacing: 0) {
                ForEach(CampUpgrade.allCases, id: \.self) { up in
                    let have = unlocked.contains(up)
                    VStack(spacing: 3) {
                        ArtGlyph(name: Self.glyph(up), color: have ? Theme.ink : Theme.inkFaint.opacity(0.45))
                            .frame(width: 26, height: 26)
                        // Earned pieces are marked by a rule beneath, not by colour alone.
                        Rectangle().fill(have ? Theme.rustDark : .clear).frame(width: 18, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .help(have ? up.title : "\(up.title) — not yet earned")
                    .accessibilityLabel("\(up.title), \(have ? "earned" : "not yet earned")")
                }
            }
            if let next = CampUpgrade.next(renown: renown) {
                HStack(spacing: 8) {
                    HUDLabel(text: "Next · \(next.upgrade.title)", size: 9.5, color: Theme.inkSoft)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().stroke(Theme.paperEdge, lineWidth: 1)
                            Rectangle().fill(Theme.ink).frame(width: max(0, g.size.width * next.progress))
                        }
                    }
                    .frame(height: 5)
                    .accessibilityLabel("Progress to \(next.upgrade.title)")
                    .accessibilityValue("\(Int(next.progress * 100)) percent")
                }
            } else {
                HUDLabel(text: "The camp is complete", size: 9.5, color: Theme.inkSoft)
            }
        }
    }

    static func glyph(_ up: CampUpgrade) -> String {
        switch up {
        case .choppingBlock: return "chopping-block"
        case .lantern: return "lantern"
        case .tent: return "tent"
        case .provisions: return "barrel"
        case .wagon: return "wagon"
        }
    }
}

// MARK: Ledger (tasks)

struct LimitChoice: Identifiable, Hashable {
    let label: String
    let seconds: TimeInterval?
    var id: String { label }
    static let all = [LimitChoice(label: "No limit", seconds: nil), LimitChoice(label: "15 min", seconds: 900),
                      LimitChoice(label: "30 min", seconds: 1800), LimitChoice(label: "1 hour", seconds: 3600),
                      LimitChoice(label: "2 hours", seconds: 7200), LimitChoice(label: "4 hours", seconds: 14400),
                      LimitChoice(label: "By sundown", seconds: -1)]

    /// Seconds from `now`; "By sundown" means 6 pm today (or one hour if that has passed).
    func resolve(now: Date) -> TimeInterval? {
        guard let s = seconds else { return nil }
        guard s < 0 else { return s }
        let six = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
        let left = six.timeIntervalSince(now)
        return left > 600 ? left : 3600
    }
}

struct LedgerTab: View {
    @ObservedObject var state: AppState
    @State private var draft = ""
    @State private var limit = LimitChoice.all[3]
    @FocusState private var typing: Bool

    private var open: [TaskItem] { state.ledger.tasks.filter { !$0.isDone } }
    private var done: [TaskItem] { state.ledger.tasks.filter(\.isDone) }

    var body: some View {
        VStack(spacing: 10) {
            HonorMeter(honor: state.ledger.honor, rank: state.rank, onPaper: true, width: 300)
                .padding(.top, 12)
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text("A task for today  #tag").foregroundStyle(Theme.inkFaint))
                    .textFieldStyle(.plain)
                    .font(Theme.body(14))
                    .focused($typing)
                    .onSubmit(add)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(Rectangle().stroke(typing ? Theme.ochre : Theme.paperEdge, lineWidth: typing ? 2 : 1))
                Picker("Time limit", selection: $limit) {
                    ForEach(LimitChoice.all) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 104)
                .controlSize(.small)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(open) { TaskRow(task: $0, state: state) }
                    if !done.isEmpty {
                        SectionRule(title: "Done today").padding(.top, 12).padding(.bottom, 2)
                        ForEach(done) { TaskRow(task: $0, state: state) }
                    }
                    if state.ledger.tasks.isEmpty {
                        VStack(spacing: 6) {
                            ArtGlyph(name: "stag-head", color: Theme.inkFaint).frame(width: 56, height: 56)
                            Text("Nothing on the books.").font(Theme.hand(22)).foregroundStyle(Theme.inkSoft)
                            Text("Finish what you set down and honor rises. Let the hours run out and it slips.")
                                .font(Theme.body(12)).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
                        }
                        .padding(.top, 40).padding(.horizontal, 30)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
        .onAppear { state.settleLedger() }
    }

    private func add() {
        let now = Date()
        state.addTask(draft, limit: limit.resolve(now: now))
        draft = ""
    }
}

struct TaskRow: View {
    let task: TaskItem
    @ObservedObject var state: AppState
    @State private var hovering = false

    private var urgency: TaskUrgency { TaskRules.urgency(task, now: state.now) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { state.toggleTask(task.id) } label: {
                ZStack {
                    Rectangle().stroke(Theme.ink, lineWidth: 1.2).frame(width: 15, height: 15)
                    if task.isDone {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark \(task.title) not done" : "Complete \(task.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(Theme.body(14))
                    .strikethrough(task.isDone, color: Theme.inkSoft)
                    .foregroundStyle(task.isDone ? Theme.inkSoft : Theme.ink)
                    .lineLimit(2)
                if !task.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(task.tags, id: \.self) { tag in
                            HUDLabel(text: tag, size: 9, color: Theme.inkSoft)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .overlay(Rectangle().stroke(Theme.paperEdge, lineWidth: 1))
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if let due = task.dueAt, !task.isDone {
                Text(dueText(due))
                    .font(Theme.body(12, urgency == .calm ? .regular : .semibold)).monospacedDigit()
                    .foregroundStyle(urgency == .calm ? Theme.inkSoft : Theme.rustDark)
            }
            Button { state.deleteTask(task.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 22, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help(task.isDone ? "Remove" : "Abandon (costs honor)")
            .accessibilityLabel("Delete \(task.title)")
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.paperEdge.opacity(0.55)).frame(height: 1) }
        .onHover { hovering = $0 }
    }

    private func dueText(_ due: Date) -> String {
        let left = due.timeIntervalSince(state.now)
        func span(_ s: TimeInterval) -> String {
            let m = Int(s / 60)
            return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(max(1, m))m"
        }
        return left >= 0 ? "\(span(left)) left" : "\(span(-left)) over"
    }
}

// MARK: Wheel loadout

struct WheelTab: View {
    @ObservedObject var state: AppState
    var onOpenWheel: () -> Void
    @State private var catalog: [AppInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hold \(state.settings.hotKey.label), point at an app, let go. Already running? You ride over to it. Not running? It's opened.")
                .font(Theme.body(12.5)).foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            SectionRule(title: "Equipped")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { i in row(i) }
                }
            }
            InkButton(title: "Open the wheel", prominent: true, action: onOpenWheel)
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
        .onAppear { if catalog.isEmpty { catalog = AppCatalog.installed() } }
    }

    private func row(_ i: Int) -> some View {
        let slots = state.settings.wheelSlots
        let app = i < slots.count ? AppCatalog.info(path: slots[i]) : nil
        return HStack(spacing: 10) {
            Text("\(i + 1)").font(Theme.display(15)).foregroundStyle(Theme.inkFaint).frame(width: 14)
            if let app {
                Image(nsImage: AppCatalog.icon(app.path)).resizable().frame(width: 26, height: 26)
                Text(app.name).font(Theme.body(14)).lineLimit(1)
            } else {
                Rectangle().stroke(Theme.paperEdge, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 26, height: 26)
                Text("Empty").font(Theme.body(14)).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            Menu {
                Button("Leave empty") { equip(i, "") }
                Divider()
                ForEach(catalog) { a in Button(a.name) { equip(i, a.path) } }
            } label: {
                HUDLabel(text: "Change", size: 10.5, color: Theme.inkSoft)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.paperEdge.opacity(0.55)).frame(height: 1) }
    }

    private func equip(_ i: Int, _ path: String) {
        var s = state.settings.wheelSlots
        while s.count < 8 { s.append("") }
        s[i] = path
        state.settings.wheelSlots = s
    }
}

// MARK: Tally (how much quota is left)

/// A quota window drawn as a ring, in the same language as the desktop cores: the ring is what is
/// *left*, so a full ring is healthy and a nearly empty one is the warning.
struct LimitRing: View {
    let limit: UsageLimit
    var size: CGFloat = 54

    private var low: Bool { limit.percentLeft < 25 }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Theme.paperEdge.opacity(0.8),
                            style: StrokeStyle(lineWidth: 4, dash: low ? [4, 3] : []))
                Circle()
                    .trim(from: 0, to: max(0.004, limit.fractionLeft))
                    .stroke(low ? Theme.rustDark : Theme.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(limit.percentLeft)")
                    .font(Theme.display(17, .heavy)).foregroundStyle(low ? Theme.rustDark : Theme.ink)
            }
            .frame(width: size, height: size)
            HUDLabel(text: limit.shortLabel, size: 9, color: Theme.inkSoft)
                .lineLimit(1).fixedSize()
        }
        .accessibilityElement()
        .accessibilityLabel("\(limit.label): \(limit.percentLeft) percent left\(low ? ", low" : "")")
    }
}

/// How much of each agent's quota is left, and when it refills.
struct TallyTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if state.limits.isEmpty {
                    VStack(spacing: 6) {
                        Text(state.limitsChecking ? "Asking your agents\u{2026}" : "No readings yet.")
                            .font(Theme.hand(22)).foregroundStyle(Theme.inkSoft)
                        Text("Each check runs the tool's own usage command.")
                            .font(Theme.body(12)).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 50)
                } else {
                    ForEach(state.limits.filter(\.available)) { provider($0) }
                    if state.limits.contains(where: { !$0.available }) {
                        HUDLabel(text: "Not installed: " + state.limits.filter { !$0.available }
                            .map(\.provider).joined(separator: ", "), size: 9, color: Theme.inkFaint)
                    }
                }

                if state.settings.trackUsage, let r = state.usage, r.all.messages > 0 {
                    SectionRule(title: "Tokens written")
                    TokenSummary(report: r)
                }

                HStack(spacing: 10) {
                    InkButton(title: state.limitsChecking ? "Checking\u{2026}" : "Check now") {
                        state.refreshLimits(force: true)
                    }
                    if let checked = state.limits.compactMap(\.checked).max() {
                        Text("as of \(checked.formatted(date: .omitted, time: .shortened))")
                            .font(Theme.body(11.5)).foregroundStyle(Theme.inkFaint)
                    }
                }
                .padding(.top, 2)
                Text("A check runs each agent's own usage command, which costs that tool one request.")
                    .font(Theme.body(11)).foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)
        }
        .onAppear {
            state.refreshLimits()
            if state.settings.trackUsage { state.refreshUsage() }
        }
    }

    @ViewBuilder
    private func provider(_ r: ProviderReading) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionRule(title: r.provider)
            if !r.limits.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(r.limits) { LimitRing(limit: $0) }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(r.limits) { l in
                        if let resets = l.resets {
                            Text("\(l.shortLabel) refills \(resets)")
                                .font(Theme.body(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        }
                    }
                }
            } else if let problem = r.problem {
                Text(problem).font(Theme.body(12.5)).foregroundStyle(problem == "no usage command" ? Theme.inkSoft : Theme.rustDark)
                if problem == "no usage command" {
                    Text("This tool has no command that reports quota.")
                        .font(Theme.body(11)).foregroundStyle(Theme.inkFaint)
                }
            }
            if let notice = r.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.rustDark)
                    Text(notice).font(Theme.body(11.5)).foregroundStyle(Theme.rustDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
            }
        }
    }
}

/// The optional token breakdown, kept behind a setting now that the Tally leads with limits.
struct TokenSummary: View {
    let report: UsageReport

    var body: some View {
        let today = report.totals(sinceDaysAgo: 1)
        let week = report.totals(sinceDaysAgo: 7)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                figure("Today", today)
                figure("Last 7 days", week)
                Spacer(minLength: 0)
            }
            Sparkline(days: report.recentDays(14))
            ForEach(report.top(report.projects, 3), id: \.name) { row in
                HStack {
                    Text(row.name).font(Theme.body(12.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(formatTokens(row.totals.output)).font(Theme.body(12.5, .semibold)).monospacedDigit()
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.paperEdge.opacity(0.5)).frame(height: 1) }
            }
        }
    }

    private func figure(_ title: String, _ t: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDLabel(text: title, size: 9, color: Theme.inkSoft)
            Text(formatTokens(t.output)).font(Theme.display(24, .heavy)).foregroundStyle(Theme.ink)
        }
    }
}

/// Daily output tokens as ink bars, oldest on the left.
struct Sparkline: View {
    let days: [(day: String, totals: UsageTotals)]

    var body: some View {
        let peak = max(1, days.map(\.totals.output).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.day) { d in
                    let share = Double(d.totals.output) / Double(peak)
                    Rectangle()
                        .fill(d.totals.output > 0 ? Theme.ink : Theme.paperEdge.opacity(0.5))
                        // A day with any work at all keeps a visible stub, so "a little" reads as more than "none".
                        .frame(height: max(d.totals.output > 0 ? 3 : 1, 40 * share))
                        .help("\(d.day): \(formatTokens(d.totals.output)) output")
                }
            }
            .frame(height: 40, alignment: .bottom)
            HStack {
                HUDLabel(text: "14 days", size: 9, color: Theme.inkFaint)
                Spacer()
                HUDLabel(text: "peak \(formatTokens(peak))", size: 9, color: Theme.inkFaint)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Daily output tokens over the last 14 days")
    }
}

// MARK: Settings

struct SettingsTab: View {
    @ObservedObject var state: AppState
    var onHotKeyChange: () -> Bool
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var hotKeyTaken = false
    @State private var mediaAllowed = MediaKeys.hasPermission
    private let displays = Displays.all()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionRule(title: "General").padding(.top, 12)
                PaperToggle(title: "Start at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    loginError = LoginItem.set(on)
                    launchAtLogin = LoginItem.isEnabled
                }))
                if let loginError {
                    Text(loginError).font(Theme.body(11.5)).foregroundStyle(Theme.rustDark)
                }

                Picker(selection: $state.settings.menuBar) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Menu bar timer").font(Theme.body(14))
                }
                .controlSize(.small)

                SectionRule(title: "On the desktop")
                PaperToggle(title: "Cores", detail: "Battery, signal, memory and CPU as rings", isOn: $state.settings.showCores)
                PaperToggle(title: "Honor meter", isOn: $state.settings.showHonorHUD)
                PaperToggle(title: "Visions", detail: "The stag when honor is good, the wolf when it is not", isOn: $state.settings.honorBackdrop)
                PaperToggle(title: "Sky follows the clock", detail: "Dawn, day, dusk and night over the camp", isOn: $state.settings.skyFollowsClock)

                SectionRule(title: "Tally")
                PaperToggle(title: "Also count tokens written",
                            detail: "Reads local Claude Code transcripts for token totals; content is never read",
                            isOn: $state.settings.trackUsage)
                if displays.count > 1 {
                    Picker(selection: $state.settings.display) {
                        Text("All displays").tag("all")
                        ForEach(displays, id: \.id) { Text($0.name).tag($0.id) }
                    } label: {
                        Text("Show on").font(Theme.body(14))
                    }
                    .controlSize(.small)
                }

                SectionRule(title: "Sound")
                PaperToggle(title: "Crackle of the fire", isOn: $state.settings.fireSound)
                PaperToggle(title: "Guitar when a timer ends", isOn: $state.settings.endSound)
                HStack {
                    Text("Volume").font(Theme.body(14))
                    Slider(value: $state.settings.volume, in: 0...1).controlSize(.small)
                }

                SectionRule(title: "Gramophone")
                HStack(spacing: 8) {
                    Text("Playlist").font(Theme.body(14))
                    TextField("", text: $state.settings.playlistURL,
                              prompt: Text("music.youtube.com/\u{2026}").foregroundStyle(Theme.inkFaint))
                        .textFieldStyle(.plain)
                        .font(Theme.body(13))
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .overlay(Rectangle().stroke(Theme.paperEdge, lineWidth: 1))
                }
                if !mediaAllowed {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Play, skip and previous need Accessibility permission, or macOS drops them silently. Volume and mute work without it.")
                            .font(Theme.body(11.5)).foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                        InkButton(title: "Grant media control") {
                            MediaKeys.requestPermission()
                            // The grant lands asynchronously, so look again shortly.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { mediaAllowed = MediaKeys.hasPermission }
                        }
                    }
                } else {
                    HUDLabel(text: "Media control granted", size: 10, color: Theme.inkSoft)
                }
                Text("Reinstalling Frontier revokes this: the app is signed afresh each build, so macOS treats it as a different app. Remove the old Frontier entry in System Settings before re-adding it.")
                    .font(Theme.body(11)).foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)

                SectionRule(title: "App wheel")
                Picker(selection: $state.settings.hotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Shortcut").font(Theme.body(14))
                }
                .controlSize(.small)
                .onChange(of: state.settings.hotKey) { hotKeyTaken = !onHotKeyChange() }
                if hotKeyTaken {
                    Text("That shortcut is claimed by another app. Pick a different one.")
                        .font(Theme.body(11.5)).foregroundStyle(Theme.rustDark)
                }

                HStack {
                    Spacer()
                    InkButton(title: "Quit Frontier", destructive: true) { NSApp.terminate(nil) }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 18).padding(.bottom, 14)
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't change the login item: \(error.localizedDescription)"
        }
    }
}
