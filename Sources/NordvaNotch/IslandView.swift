import NordvaNotchCore
import SwiftUI

enum Palette {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let done = Color(red: 0.32, green: 0.82, blue: 0.48)
    static let waiting = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let failed = Color(red: 1.0, green: 0.38, blue: 0.35)
    static let working = Color(red: 0.45, green: 0.66, blue: 1.0)
    static let quiet = Color.white.opacity(0.45)
    static let secondary = Color.white.opacity(0.58)
    static let hover = Color.white.opacity(0.09)

    static func color(for status: SessionStatus, stalled: Bool = false) -> Color {
        if stalled { return quiet }
        switch status {
        case .idle: return quiet
        case .working: return working
        case .waiting: return waiting
        case .done: return done
        case .failed: return failed
        }
    }
}

/// The notch outline: square top against the screen edge, round bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(radius, rect.width / 2, rect.height))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    private var size: IslandLayout.Size { IslandLayout.size(of: model.mode, anchor: model.anchor) }
    private var isIdle: Bool { model.mode == .idle }
    private var radius: CGFloat {
        switch model.mode {
        case .idle, .compact: return 9
        case .peek: return 20
        case .banner, .list: return 24
        }
    }

    /// The content grows out of the notch: fade in from 85% size, pinned to the top.
    private var reveal: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.85, anchor: .top))
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(radius: radius)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                // Behind the notch the idle shape is invisible anyway; without a notch there is nothing to show.
                .opacity(isIdle && !model.anchor.hasNotch ? 0 : 1)

            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(radius: radius))
        }
        .frame(width: IslandLayout.canvasWidth, height: IslandLayout.canvasHeight, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: model.mode)
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .idle:
            // A click on the notch opens the list.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.openList)
        case .compact:
            CompactView(model: model)
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.openList)
                .transition(.opacity)
        case .banner:
            BannerView(model: model, actions: actions)
                .transition(reveal)
        case .peek:
            PeekView(model: model, actions: actions)
                .transition(reveal)
        case .list:
            ListView(model: model, actions: actions)
                .transition(reveal)
        }
    }
}

// MARK: - Peek

/// The strip that slides out while the pointer rests on the notch: one pill per session.
private struct PeekView: View {
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    private var pills: [SessionRow] { Array(model.rows.prefix(IslandLayout.maxPills)) }

    var body: some View {
        let width = IslandLayout.pillWidth(count: pills.count, anchor: model.anchor)
        VStack(spacing: 0) {
            Color.clear
                .frame(height: model.anchor.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.openList)
            Spacer().frame(height: IslandLayout.pillTop)
            HStack(spacing: IslandLayout.pillSpacing) {
                ForEach(Array(pills.enumerated()), id: \.element.id) { index, row in
                    Pill(row: row, hovered: model.peekHover == index)
                        .frame(width: width, height: IslandLayout.pillHeight)
                        .contentShape(Capsule())
                        .onTapGesture { actions.open(row) }
                        .handCursor()
                }
            }
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.top, 7)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.openList)
    }

    private var hovered: SessionRow? {
        model.peekHover.flatMap { pills.indices.contains($0) ? pills[$0] : nil }
    }

    private var detail: String {
        if let row = hovered { return TurnText.summary(of: row, now: Date()) }
        var parts: [String] = []
        let rows = model.rows
        let working = rows.filter { $0.status == .working && !$0.stalled }.count
        let waiting = rows.filter { $0.status == .waiting }.count
        let done = rows.filter { $0.status == .done }.count
        let failed = rows.filter { $0.status == .failed }.count
        if waiting > 0 { parts.append("\(waiting) needs you") }
        if working > 0 { parts.append("\(working) working") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        let more = model.rows.count - pills.count + model.hiddenCount
        if more > 0 { parts.append("+\(more) more") }
        if let limits = TurnText.limits(model) { parts.append(limits.text) }
        return parts.isEmpty ? "Click for all sessions" : parts.joined(separator: " · ")
    }

    private var detailColor: Color {
        guard let row = hovered else { return Palette.secondary }
        return row.stalled ? Palette.quiet : Palette.color(for: row.status)
    }
}

private struct Pill: View {
    let row: SessionRow
    let hovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            if row.status == .working && !row.stalled {
                Spinner(color: NSColor(Palette.working), size: 9)
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(Palette.color(for: row.status, stalled: row.stalled))
                    .frame(width: 7, height: 7)
            }
            Text(row.title)
                .font(.system(size: 11, weight: row.unseen ? .bold : .semibold))
                .foregroundStyle(row.unseen ? Color.white : Color.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color.white.opacity(hovered ? 0.2 : 0.1)))
    }
}

// MARK: - Compact

private struct CompactView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let wing = IslandLayout.wingWidth(timer: model.timerRunning)
        HStack(spacing: 0) {
            left.frame(width: wing)
            Spacer(minLength: model.anchor.notchWidth)
            right.frame(width: wing)
        }
        .frame(height: model.anchor.height)
    }

    private var working: Bool { model.showWorking && model.workingCount > 0 }
    private var attention: SessionStatus? { model.showAttention ? model.attention : nil }
    private var unseen: Int { model.showAttention ? model.unseenCount : 0 }

    @ViewBuilder private var left: some View {
        if working {
            Spinner(color: NSColor(Palette.working), size: 12)
                .frame(width: 12, height: 12)
        } else if let status = attention {
            dot(Palette.color(for: status))
        } else if model.timerDone {
            dot(Palette.done)
        } else if model.timerRunning {
            Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.waiting)
        }
    }

    private func dot(_ color: Color, size: CGFloat = 8) -> some View {
        Circle().fill(color).frame(width: size, height: size).shadow(color: color.opacity(0.8), radius: 4)
    }

    @ViewBuilder private var right: some View {
        if let end = model.timerEnd {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TimeText.shortCountdown(end.timeIntervalSince(context.date)))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else if unseen > 0 {
            HStack(spacing: 4) {
                // The spinner holds the left wing, so the result's colour moves here.
                if working, let status = attention { dot(Palette.color(for: status), size: 6) }
                Text("\(unseen)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        } else if model.timerDone {
            Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.done)
        } else if working {
            Text("\(model.workingCount)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.working)
        }
    }
}

// MARK: - Banner

private struct BannerView: View {
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    var body: some View {
        VStack(spacing: 0) {
            // The strip beside the notch opens the whole list; the event below opens its session.
            Color.clear
                .frame(height: model.anchor.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.openList)
            switch model.banner {
            case .session(let row):
                event(
                    symbol: row.status == .working ? "ellipsis" : symbol(for: row),
                    tint: Palette.color(for: row.status),
                    title: row.title,
                    detail: detail(for: row),
                    trailing: trailing(for: row)
                )
                .contentShape(Rectangle())
                .onTapGesture { actions.open(row) }
                .handCursor()
            case .reminder(let row):
                event(
                    symbol: symbol(for: row),
                    tint: Palette.color(for: row.status),
                    title: row.title,
                    detail: detail(for: row),
                    trailing: TurnText.waitingFor(row, now: Date())
                )
                .contentShape(Rectangle())
                .onTapGesture { actions.open(row) }
                .handCursor()
            case .heavy(let row):
                event(
                    symbol: "flame.fill",
                    tint: Palette.waiting,
                    title: row.title,
                    detail: TurnText.heavyDetail(of: row, now: Date()),
                    trailing: row.costLong ?? ""
                )
                .contentShape(Rectangle())
                .onTapGesture { actions.open(row) }
                .handCursor()
            case .window(let cost):
                event(
                    symbol: "flame.fill",
                    tint: Palette.waiting,
                    title: "Heavy five hours",
                    detail: "All sessions and agents together, at API prices",
                    trailing: "≈ " + UsageText.cost(cost)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.openList)
                .handCursor()
            case .planLimit(let five, let week):
                event(
                    symbol: "hourglass",
                    tint: Palette.waiting,
                    title: "Five-hour limit at \(five.exact ? "" : "≈")\(Int(five.percent.rounded()))%",
                    detail: "Resets at " + TurnText.clock(five.resetsAt)
                        + (week.map { " · week \(Int($0.percent.rounded()))%" } ?? ""),
                    trailing: "\(Int(five.percent.rounded()))%"
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.openList)
                .handCursor()
            case .limitReset(let peak, let week):
                event(
                    symbol: "arrow.clockwise",
                    tint: Palette.done,
                    title: "Five-hour limit reset",
                    detail: "It got to \(Int(peak.rounded()))%" + (week.map { " · week \(Int($0.percent.rounded()))%" } ?? ""),
                    trailing: "Fresh"
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.dismissBanner)
                .handCursor()
            case .context(let row):
                event(
                    symbol: "gauge.with.dots.needle.67percent",
                    tint: Palette.waiting,
                    title: row.title,
                    detail: "\(row.project) · context nearly full, compaction is near",
                    trailing: row.contextPercent.map { "\($0)%" } ?? ""
                )
                .contentShape(Rectangle())
                .onTapGesture { actions.open(row) }
                .handCursor()
            case .timer(let minutes):
                event(symbol: "timer", tint: Palette.done, title: "Time is up", detail: "\(minutes) min timer", trailing: TimeText.countdown(Double(minutes) * 60))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: actions.dismissBanner)
                    .handCursor()
            case nil:
                Spacer()
            }
        }
    }

    private func event(symbol: String, tint: Color, title: String, detail: String, trailing: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .frame(width: IslandLayout.bannerWidth, height: IslandLayout.bannerBody)
    }

    private func symbol(for row: SessionRow) -> String {
        StatusBadge.symbol(status: row.status, waitReason: row.record.waitReason, stalled: false)
    }

    private func detail(for row: SessionRow) -> String {
        var parts = [row.project]
        if row.status == .done || row.status == .failed {
            if let duration = TurnText.duration(of: row, now: Date()) { parts.append(duration) }
            if let cost = TurnText.cost(of: row) { parts.append(cost) }
            if let background = SessionNaming.backgroundText(of: row.record) { parts.append(background) }
        }
        if row.status == .done, model.showReply, let reply = row.reply {
            parts.append(reply)
        } else if row.status != .done {
            parts.append(row.statusText)
        }
        return parts.joined(separator: " · ")
    }

    private func trailing(for row: SessionRow) -> String {
        switch row.status {
        case .done: return "Done"
        case .waiting: return "Needs you"
        case .failed: return "Failed"
        case .working: return "Working"
        case .idle: return ""
        }
    }
}

/// The strip level with the notch: content only fits left and right of it.
private struct Band<Trailing: View>: View {
    @ObservedObject var model: IslandModel
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.claude)
            Text((model.workingCount > 0 ? "\(model.workingCount) working" : "Claude Code")
                 + (model.hiddenCount > 0 ? " · +\(model.hiddenCount)" : ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Spacer(minLength: model.anchor.notchWidth + 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: model.anchor.height)
    }
}

// MARK: - List

private struct ListView: View {
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    var body: some View {
        VStack(spacing: 0) {
            Band(model: model) {
                if let limits = TurnText.limits(model) {
                    // Only the five hours fit beside the notch; the week is in the tooltip and the peek strip.
                    Text(limits.short)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(limits.warn ? Palette.waiting : Palette.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(limits.help)
                }
                Button(action: actions.openSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .help("Settings")
            }
            Spacer().frame(height: IslandLayout.listHeader + IslandLayout.listPadding)
            if model.rows.isEmpty {
                VStack(spacing: 4) {
                    Text("No Claude Code sessions yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("They show up here after their next prompt.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                .frame(height: IslandLayout.rowHeight)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        RowView(row: row, warnPercent: model.contextWarnPercent,
                                selected: model.selectedRow == model.rows.firstIndex(of: row)) { actions.open(row) }
                            .frame(height: IslandLayout.rowHeight)
                    }
                }
                .padding(.horizontal, 8)
            }
            if model.timerEnabled {
                footer
                    .frame(height: IslandLayout.listFooter)
                    .padding(.horizontal, 16)
                Spacer().frame(height: IslandLayout.listPadding)
            } else {
                Spacer().frame(height: IslandLayout.listEnd)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let end = model.timerEnd {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.waiting)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(TimeText.countdown(end.timeIntervalSince(context.date)))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 4)
                Chip(title: "+1 min", action: actions.addMinute)
                Chip(title: "Stop", action: actions.stopTimer)
            } else {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .padding(.trailing, 2)
                ForEach([5, 10, 15, 25, 45], id: \.self) { minutes in
                    Chip(title: "\(minutes)m") { actions.startTimer(minutes) }
                }
            }
            Spacer(minLength: 4)
        }
    }
}

private struct RowView: View {
    let row: SessionRow
    let warnPercent: Int
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            StatusBadge(status: row.status, waitReason: row.record.waitReason, stalled: row.stalled, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 13, weight: row.unseen ? .bold : .semibold))
                        .foregroundStyle(row.unseen ? .white : .white.opacity(0.85))
                        .lineLimit(1)
                    if row.unseen {
                        Circle().fill(Palette.color(for: row.status)).frame(width: 6, height: 6)
                    }
                }
                subtitle
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                TimelineView(.periodic(from: .now, by: row.status == .working ? 1 : 30)) { context in
                    // A working row counts the turn up; any other row says how long ago it stopped.
                    Text(row.status == .working && !row.stalled
                         ? TurnText.duration(of: row, now: context.date) ?? TimeText.ago(context.date.timeIntervalSince(row.since))
                         : TimeText.ago(context.date.timeIntervalSince(row.since)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(row.status == .working ? Palette.working : Palette.secondary)
                }
                if let cost = TurnText.cost(of: row) {
                    Text(cost)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover || selected ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .handCursor()
    }

    private var contextText: Text {
        guard let percent = row.contextPercent else { return Text("") }
        let full = warnPercent > 0 && percent >= warnPercent
        return Text(" · ctx \(percent)%").foregroundColor(full ? Palette.waiting : Palette.secondary)
    }

    /// Context comes before the reply, which is long and gets cut.
    private var subtitle: Text {
        func plain(_ text: String) -> Text { Text(text).foregroundColor(Palette.secondary) }
        if row.stalled { return plain("\(row.project) · No activity for a while") }
        if row.status == .done, let reply = row.reply {
            let duration = TurnText.duration(of: row, now: Date()).map { " · " + $0 } ?? ""
            let background = SessionNaming.backgroundText(of: row.record)
                .map { Text(" · " + $0).foregroundColor(Palette.working) } ?? Text("")
            return plain("\(row.project)\(duration)") + background + contextText + plain(" · \(reply)")
        }
        return plain("\(row.project) · \(row.statusText)") + contextText
    }
}

/// Short phrases about a turn: how long, how much, how many agents.
enum TurnText {
    static func duration(of row: SessionRow, now: Date) -> String? {
        SessionBoard.turnSeconds(of: row.record, now: now.timeIntervalSince1970).map(UsageText.duration)
    }

    /// "≈3%" of the plan's five hours, or "≈ $0.42" on API billing.
    static func cost(of row: SessionRow) -> String? {
        row.costShort
    }

    static func clock(_ time: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: time)) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }

    /// The plan's limits when Claude Code reports them, otherwise the last five hours at API prices.
    static func limits(_ model: IslandModel) -> (text: String, short: String, help: String, warn: Bool)? {
        if let five = model.fiveHour {
            let percent = Int(five.percent.rounded())
            let mark = five.exact ? "" : "≈"
            var text = "5h \(mark)\(percent)%"
            var help = "Five-hour limit, resets at \(clock(five.resetsAt))"
                + (five.exact ? "" : ". Carried forward from Claude Code's last report with the usage since")
            if let week = model.sevenDay {
                text += " · 7d \(Int(week.percent.rounded()))%"
                help += "; weekly limit resets \(clock(week.resetsAt))"
            }
            return (text, "5h \(mark)\(percent)%", help, percent >= 80)
        }
        guard let cost = model.windowCost else { return nil }
        let text = "5h ≈ " + UsageText.cost(cost)
        return (text, text, "Every session and agent over the last five hours, at API prices", false)
    }

    static func agents(of row: SessionRow) -> String? {
        guard let count = row.usage?.agents, count > 0 else { return nil }
        return count == 1 ? "1 agent" : "\(count) agents"
    }

    /// For the pill under the pointer.
    static func summary(of row: SessionRow, now: Date) -> String {
        if row.stalled { return "\(row.project) · No activity for a while" }
        var parts = [row.project]
        let duration = Self.duration(of: row, now: now)
        switch row.status {
        case .working: parts.append(duration.map { "Working \($0)" } ?? "Working")
        case .done:
            parts.append(duration.map { "Done in \($0)" } ?? "Done")
            if let background = SessionNaming.backgroundText(of: row.record) { parts.append(background) }
        default: parts.append(row.statusText)
        }
        if let cost = row.costLong { parts.append(cost) }
        if let agents = agents(of: row) { parts.append(agents) }
        if let percent = row.contextPercent { parts.append("ctx \(percent)%") }
        if row.status == .done, let reply = row.reply { parts.append(reply) }
        return parts.joined(separator: " · ")
    }

    /// For a reminder: how long it has been waiting or unseen.
    static func waitingFor(_ row: SessionRow, now: Date) -> String {
        let ago = TimeText.ago(now.timeIntervalSince(row.since))
        return row.status == .waiting ? "Waiting \(ago)" : "Unseen \(ago)"
    }

    static func heavyDetail(of row: SessionRow, now: Date) -> String {
        var parts = [row.project]
        if let usage = row.usage { parts.append(UsageText.tokens(usage.tokens) + " tokens") }
        if let agents = agents(of: row) { parts.append(agents) }
        if let duration = duration(of: row, now: now) { parts.append(duration) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pieces

struct StatusBadge: View {
    let status: SessionStatus
    let waitReason: WaitReason?
    let stalled: Bool
    let size: CGFloat
    @State private var spin = false

    var body: some View {
        let color = Palette.color(for: status, stalled: stalled)
        ZStack {
            Circle().fill(color.opacity(0.17))
            if status == .working && !stalled {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .padding(size * 0.24)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            } else {
                Image(systemName: Self.symbol(status: status, waitReason: waitReason, stalled: stalled))
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }

    static func symbol(status: SessionStatus, waitReason: WaitReason?, stalled: Bool) -> String {
        if stalled { return "pause.fill" }
        switch status {
        case .idle: return "moon.fill"
        case .working: return "ellipsis"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        case .waiting:
            switch waitReason {
            case .question: return "questionmark"
            case .plan: return "list.bullet.clipboard"
            case .permission: return "hand.raised.fill"
            case .input, .none: return "bubble.left.fill"
            }
        }
    }
}

struct Chip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(ChipStyle())
    }
}

private struct ChipStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.26 : hover ? 0.18 : 0.1)))
            .onHover { hover = $0 }
            .handCursor()
    }
}

struct HoverButtonStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover ? Color.white : Palette.secondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(configuration.isPressed ? 0.2 : hover ? 0.1 : 0)))
            .onHover { hover = $0 }
            .handCursor()
    }
}

extension View {
    @ViewBuilder func handCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

/// A spinning arc driven by Core Animation: the window server turns it, so a spinner that may stay
/// on screen for hours costs the app no redraws.
struct Spinner: NSViewRepresentable {
    let color: NSColor
    let size: CGFloat

    func makeNSView(context: Context) -> SpinnerView {
        SpinnerView(color: color, size: size)
    }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.arc.strokeColor = color.cgColor
    }
}

final class SpinnerView: NSView {
    let arc = CAShapeLayer()
    private let side: CGFloat

    init(color: NSColor, size: CGFloat) {
        side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.2, dy: 1.2), transform: nil)
        arc.fillColor = nil
        arc.strokeColor = color.cgColor
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeEnd = 0.7
        layer?.addSublayer(arc)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
}
