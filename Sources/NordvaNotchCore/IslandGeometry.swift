/// Plain geometry so the layout can be tested without AppKit. Coordinates are AppKit screen
/// points: the origin is bottom-left and y grows upwards.
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px < maxX && py >= minY && py < maxY
    }
}

public struct ScreenShape: Equatable, Sendable {
    public var frame: Rect
    public var safeAreaTop: Double
    public var auxiliaryTopLeft: Rect?
    public var auxiliaryTopRight: Rect?
    /// Height of the menu bar on this screen, 0 when the screen has none.
    public var menuBarHeight: Double

    public init(frame: Rect, safeAreaTop: Double, auxiliaryTopLeft: Rect?, auxiliaryTopRight: Rect?, menuBarHeight: Double) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.menuBarHeight = menuBarHeight
    }

    public var hasNotch: Bool {
        guard safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight else { return false }
        return frame.width - left.width - right.width > 0
    }
}

/// Where the island hangs from: the camera notch, or the middle of the top edge on a screen without one.
public struct NotchAnchor: Equatable, Sendable {
    public var centerX: Double
    public var top: Double
    public var notchWidth: Double
    public var height: Double
    public var hasNotch: Bool

    public init(centerX: Double, top: Double, notchWidth: Double, height: Double, hasNotch: Bool) {
        self.centerX = centerX
        self.top = top
        self.notchWidth = notchWidth
        self.height = height
        self.hasNotch = hasNotch
    }

    /// The menu bar is usually 24 pt on a screen without a notch.
    public static let fallbackHeight = 24.0
    /// A screen without a notch gets a virtual one this wide, the gap between the wings of the pill.
    public static let virtualNotchWidth = 120.0

    public init(screen: ScreenShape) {
        if screen.hasNotch, let left = screen.auxiliaryTopLeft, let right = screen.auxiliaryTopRight {
            // Widths only: they mean the same whatever the origin of the auxiliary areas is,
            // even when the built-in display is not the one at (0, 0).
            let width = screen.frame.width - left.width - right.width
            self.init(
                centerX: screen.frame.minX + left.width + width / 2,
                top: screen.frame.maxY,
                notchWidth: width,
                height: screen.safeAreaTop,
                hasNotch: true
            )
        } else {
            self.init(
                centerX: screen.frame.midX,
                top: screen.frame.maxY,
                notchWidth: Self.virtualNotchWidth,
                height: screen.menuBarHeight > 0 ? screen.menuBarHeight : Self.fallbackHeight,
                hasNotch: false
            )
        }
    }
}

public enum IslandMode: Equatable, Sendable {
    /// Nothing to show: exactly the notch, or nothing at all on a screen without one.
    case idle
    /// Small wings either side of the notch: a status dot and a count, or a running timer,
    /// which needs the wider wings so its digits keep clear of the edge.
    case compact(timer: Bool)
    /// One event, expanded for a few seconds.
    case banner
    /// A strip of session pills while the pointer rests on the notch.
    case peek(pills: Int)
    /// The full list, opened by a click; the timer row at the bottom only when the timer is on.
    case list(rows: Int, timer: Bool)
}

public enum IslandLayout {
    public static let wing = 36.0
    public static let timerWing = 52.0
    public static let bannerWidth = 440.0
    public static let bannerBody = 64.0
    public static let listWidth = 440.0
    public static let listHeader = 6.0
    public static let rowHeight = 50.0
    public static let maxVisibleRows = 6
    public static let listFooter = 52.0
    public static let listPadding = 10.0
    /// Below the last row when there is no timer row; a little more than the padding,
    /// so a highlighted row stays clear of the round corners.
    public static let listEnd = 14.0
    public static let peekWidth = 500.0
    public static let peekBody = 62.0
    public static let peekPadding = 16.0
    public static let pillTop = 8.0
    public static let pillHeight = 28.0
    public static let pillSpacing = 6.0
    public static let maxPillWidth = 160.0
    /// Three pills keep about twenty characters of a title readable; the rest go into "+N more".
    public static let maxPills = 3
    /// The panel is this big and never moves; only the shape inside it animates.
    public static let canvasWidth = 560.0
    public static let canvasHeight = 520.0

    public static func wingWidth(timer: Bool) -> Double {
        timer ? timerWing : wing
    }

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double
    }

    public static func size(of mode: IslandMode, anchor: NotchAnchor) -> Size {
        let notch = anchor.notchWidth
        switch mode {
        case .idle:
            return Size(width: notch, height: anchor.height)
        case .compact(let timer):
            return Size(width: notch + wingWidth(timer: timer) * 2, height: anchor.height)
        case .banner:
            return Size(width: max(bannerWidth, notch + wing * 2), height: anchor.height + bannerBody)
        case .peek:
            return Size(width: max(peekWidth, notch + wing * 2), height: anchor.height + peekBody)
        case .list(let rows, let timer):
            let visible = Double(min(max(rows, 1), maxVisibleRows))
            let bottom = timer ? listFooter + listPadding : listEnd
            let body = listHeader + listPadding + visible * rowHeight + bottom
            return Size(width: max(listWidth, notch + wing * 2), height: anchor.height + body)
        }
    }

    /// The shape's rectangle on screen, hanging from the top edge, centred on the notch.
    public static func frame(of mode: IslandMode, anchor: NotchAnchor) -> Rect {
        let size = size(of: mode, anchor: anchor)
        return Rect(x: anchor.centerX - size.width / 2, y: anchor.top - size.height, width: size.width, height: size.height)
    }

    /// Pills share the strip equally, up to `maxPillWidth`, and the row is centred.
    public static func pillWidth(count: Int, anchor: NotchAnchor) -> Double {
        guard count > 0 else { return 0 }
        let width = size(of: .peek(pills: count), anchor: anchor).width
        let room = width - peekPadding * 2 - pillSpacing * Double(count - 1)
        return min(maxPillWidth, room / Double(count))
    }

    /// Which pill is under the pointer, from coordinates alone: hover tracking in a panel that
    /// never becomes key is not reliable, the pointer position is.
    public static func pillIndex(x: Double, y: Double, count: Int, anchor: NotchAnchor) -> Int? {
        guard count > 0 else { return nil }
        let top = anchor.top - anchor.height - pillTop
        guard y <= top, y > top - pillHeight else { return nil }
        let pill = pillWidth(count: count, anchor: anchor)
        let row = pill * Double(count) + pillSpacing * Double(count - 1)
        let offset = x - (anchor.centerX - row / 2)
        guard offset >= 0, offset < row else { return nil }
        let index = Int(offset / (pill + pillSpacing))
        // The gap between two pills belongs to neither.
        guard offset - Double(index) * (pill + pillSpacing) < pill else { return nil }
        return index
    }

    /// Room around the shape for the spring's overshoot.
    public static let panelMargin = 16.0

    /// The panel that hosts the shape: just the shape and a margin, top edge flush with the screen.
    /// A transparent panel larger than that would still get hover tracking over its whole area.
    public static func panelFrame(for mode: IslandMode, anchor: NotchAnchor) -> Rect {
        let shape = frame(of: mode, anchor: anchor)
        return Rect(
            x: shape.minX - panelMargin,
            y: shape.minY - panelMargin,
            width: shape.width + panelMargin * 2,
            height: shape.height + panelMargin
        )
    }

    /// The fixed panel that hosts the shape.
    public static func canvas(anchor: NotchAnchor) -> Rect {
        Rect(x: anchor.centerX - canvasWidth / 2, y: anchor.top - canvasHeight, width: canvasWidth, height: canvasHeight)
    }

    /// Whether the pointer should reach the island: inside the shape, or on the notch itself so a
    /// click there opens the list. A screen without a notch has nothing to click while idle.
    public static func isInteractive(mode: IslandMode, anchor: NotchAnchor, x: Double, y: Double) -> Bool {
        if mode == .idle && !anchor.hasNotch { return false }
        return frame(of: mode, anchor: anchor).contains(x: x, y: y)
    }
}
