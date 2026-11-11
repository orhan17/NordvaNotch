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

/// The notch outline: flat top that flares into the screen edge, straight sides, round bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set {
            ear = newValue.first
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, (rect.width - ear * 2) / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + ear + r, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    private var size: IslandLayout.Size { IslandLayout.size(of: model.mode, anchor: model.anchor) }
    private var isIdle: Bool { model.mode == .idle }
    private var isExpanded: Bool {
        if case .list = model.mode { return true }
        return model.mode == .banner
    }

    private var ear: CGFloat { isIdle ? 0 : 7 }
    private var radius: CGFloat {
        switch model.mode {
        case .idle: return 10
        case .compact: return 11
        case .banner: return 22
        case .list: return 26
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(ear: ear, radius: radius)
                .fill(Color.black)
                .frame(width: size.width + ear * 2, height: size.height)
                .shadow(color: .black.opacity(isExpanded ? 0.5 : 0), radius: 16, y: 6)
                .opacity(isIdle ? 0 : 1)

            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(ear: 0, radius: radius))
        }
        .frame(width: IslandLayout.canvasWidth, height: IslandLayout.canvasHeight, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.mode)
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .idle:
            // Invisible, but a click on the notch still opens the list.
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
                .transition(.opacity.animation(.easeIn(duration: 0.18).delay(0.1)))
        case .list:
            ListView(model: model, actions: actions)
                .transition(.opacity.animation(.easeIn(duration: 0.18).delay(0.1)))
        }
    }
}

// MARK: - Compact

private struct CompactView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: IslandLayout.wing)
            Spacer(minLength: model.anchor.notchWidth)
            right.frame(width: IslandLayout.wing)
        }
        .frame(height: model.anchor.height)
    }

    @ViewBuilder private var left: some View {
        if let status = model.attention {
            Circle().fill(Palette.color(for: status)).frame(width: 8, height: 8)
                .shadow(color: Palette.color(for: status).opacity(0.8), radius: 4)
        } else if model.timerRunning {
            Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.waiting)
        }
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
        } else if model.unseenCount > 0 {
            Text("\(model.unseenCount)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Banner

private struct BannerView: View {
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    var body: some View {
        VStack(spacing: 0) {
            Band(model: model) {
                Button(action: actions.openList) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .help("All sessions")
            }
            switch model.banner {
            case .session(let row):
                sessionBody(row)
            case .timer(let minutes):
                timerBody(minutes)
            case nil:
                Spacer()
            }
        }
    }

    private func sessionBody(_ row: SessionRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatusBadge(status: row.status, waitReason: row.record.waitReason, stalled: false, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(row.project) · \(row.statusText)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.color(for: row.status))
                    .lineLimit(1)
                if model.showReply, let reply = row.reply, row.status == .done {
                    Text(reply)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { actions.open(row) }
        .handCursor()
    }

    private func timerBody(_ minutes: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.waiting.opacity(0.18))
                Image(systemName: "timer").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.waiting)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Time is up").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("\(minutes) min timer").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Chip(title: "Again") { actions.startTimer(minutes) }
            Chip(title: "OK", action: actions.dismissBanner)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The strip level with the notch: content only fits left and right of it.
private struct Band<Trailing: View>: View {
    @ObservedObject var model: IslandModel
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.claude)
            Text(model.workingCount > 0 ? "\(model.workingCount) working" : "Claude Code")
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
                if model.hiddenCount > 0 {
                    Text("+\(model.hiddenCount) older")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
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
                        RowView(row: row) { actions.open(row) }
                            .frame(height: IslandLayout.rowHeight)
                    }
                }
                .padding(.horizontal, 8)
            }
            footer
                .frame(height: IslandLayout.listFooter)
                .padding(.horizontal, 16)
            Spacer().frame(height: IslandLayout.listPadding)
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
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .help("Settings")
        }
    }
}

private struct RowView: View {
    let row: SessionRow
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
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(TimeText.ago(context.date.timeIntervalSince(row.since)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .handCursor()
    }

    private var subtitle: String {
        if row.stalled { return "\(row.project) · No activity for a while" }
        if row.status == .done, let reply = row.reply { return "\(row.project) · \(reply)" }
        return "\(row.project) · \(row.statusText)"
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
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }

    private var symbol: String {
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
