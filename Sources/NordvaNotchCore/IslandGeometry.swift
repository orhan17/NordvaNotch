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
        return right.minX - left.maxX > 0
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
            let width = right.minX - left.maxX
            self.init(
                centerX: left.maxX + width / 2,
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
    /// Small wings either side of the notch: a status dot and a count or a running timer.
    case compact
    /// One event, expanded for a few seconds.
    case banner
    /// The full list, opened by a click.
    case list(rows: Int)
}

public enum IslandLayout {
    public static let wing = 36.0
    public static let bannerWidth = 420.0
    public static let bannerBody = 78.0
    public static let listWidth = 460.0
    public static let listHeader = 6.0
    public static let rowHeight = 50.0
    public static let maxVisibleRows = 6
    public static let listFooter = 52.0
    public static let listPadding = 10.0
    /// The panel is this big and never moves; only the shape inside it animates.
    public static let canvasWidth = 560.0
    public static let canvasHeight = 520.0

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double
    }

    public static func size(of mode: IslandMode, anchor: NotchAnchor) -> Size {
        let notch = anchor.notchWidth
        switch mode {
        case .idle:
            return Size(width: notch, height: anchor.height)
        case .compact:
            return Size(width: notch + wing * 2, height: anchor.height)
        case .banner:
            return Size(width: max(bannerWidth, notch + wing * 2), height: anchor.height + bannerBody)
        case .list(let rows):
            let visible = Double(min(max(rows, 1), maxVisibleRows))
            let body = listHeader + visible * rowHeight + listFooter + listPadding * 2
            return Size(width: max(listWidth, notch + wing * 2), height: anchor.height + body)
        }
    }

    /// The shape's rectangle on screen, hanging from the top edge, centred on the notch.
    public static func frame(of mode: IslandMode, anchor: NotchAnchor) -> Rect {
        let size = size(of: mode, anchor: anchor)
        return Rect(x: anchor.centerX - size.width / 2, y: anchor.top - size.height, width: size.width, height: size.height)
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
