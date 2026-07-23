import CoreGraphics

/// Pure layout math for the live-call caption line-count feature (scroll over the
/// caption to show more or fewer lines). Kept in Core, free of AppKit/SwiftUI, so
/// the two load-bearing decisions can be unit-tested:
///
/// 1. `CaptionLineAdaptation`: given the height actually available and the line
///    count the user picked, how many lines to render and at what font scale. The
///    chosen line count is a *preference ceiling*, not a hard reserve: when the
///    window is too short, the caption shows fewer lines and/or scales its font
///    down rather than forcing the window taller. This is why the caption line
///    count never needs to grow the window's minimum size (BUG 1).
///
/// 2. `CaptionScrollHitRegion`: a scroll-capture rectangle that stays stable as
///    the caption box grows and shrinks, so repeated scroll steps register from
///    one fixed hover position without re-homing the mouse (BUG 2).

public struct CaptionLineFit: Equatable {
    /// Lines to actually render (>= 1, <= the chosen ceiling).
    public let visibleLines: Int
    /// Font scale to apply (<= 1). 1 means the chosen font fits as-is.
    public let scale: CGFloat

    public init(visibleLines: Int, scale: CGFloat) {
        self.visibleLines = visibleLines
        self.scale = scale
    }
}

public enum CaptionLineAdaptation {
    /// Never scale a caption smaller than this fraction of its chosen font.
    public static let minScale: CGFloat = 0.6

    /// Vertical chrome (padding + shadow band) around the caption text, in points.
    static let verticalChrome: CGFloat = 24

    /// Approximate rendered height of one caption line at `fontSize`, including
    /// inter-line spacing. Semibold system text plus the flow layout's line
    /// spacing lands near 1.35x the point size.
    public static func perLineHeight(fontSize: CGFloat) -> CGFloat {
        max(1, fontSize * 1.35 + 4)
    }

    /// Decide how many lines to show and at what scale.
    ///
    /// - `availableHeight`: height the caption band may occupy. Pass `.infinity`
    ///   (or a non-positive value) when the budget is unknown, and the user's
    ///   chosen ceiling is honored verbatim at full scale, so normal-sized
    ///   windows behave exactly as before.
    /// - `chosenLineCount`: the user's picked ceiling.
    /// - `fontSize`: the user's caption font size.
    /// - `maxLineCount`: the hard upper bound of the line-count range.
    public static func fit(
        availableHeight: CGFloat,
        chosenLineCount: Int,
        fontSize: CGFloat,
        maxLineCount: Int
    ) -> CaptionLineFit {
        let ceiling = max(1, min(chosenLineCount, max(1, maxLineCount)))
        guard availableHeight.isFinite, availableHeight > 0 else {
            return CaptionLineFit(visibleLines: ceiling, scale: 1)
        }

        let lineHeight = perLineHeight(fontSize: fontSize)
        let usable = max(0, availableHeight - verticalChrome)

        // How many whole lines fit at full size (at least one).
        let wholeLines = max(1, Int((usable / lineHeight).rounded(.down)))
        let visible = max(1, min(ceiling, wholeLines))

        // If even a single line cannot fit at full size, scale the font down
        // (never below `minScale`) so a very short window still shows a caption
        // rather than pushing the window taller.
        var scale: CGFloat = 1
        if usable < lineHeight {
            scale = max(minScale, usable / lineHeight)
        }
        return CaptionLineFit(visibleLines: visible, scale: scale)
    }
}

public enum CaptionScrollHitRegion {
    /// The tallest a caption can get, for `maxLineCount` lines at `fontSize`.
    /// Used as the height of the stable scroll band so the cursor stays inside
    /// it no matter which line count is currently displayed.
    public static func maxBandHeight(fontSize: CGFloat, maxLineCount: Int) -> CGFloat {
        let lines = CGFloat(max(1, maxLineCount))
        return CaptionLineAdaptation.perLineHeight(fontSize: fontSize) * lines
            + CaptionLineAdaptation.verticalChrome
    }

    /// The stable hit rectangle for the caption scroll monitor, in AppKit window
    /// coordinates (origin bottom-left, y increasing upward).
    ///
    /// The caption box is bottom-anchored: as the line count changes, its bottom
    /// edge (`captionFrame.minY`) stays put while its top edge rises and falls.
    /// Hit-testing the raw box means one scroll step resizes the box out from
    /// under the pointer, so the next step is ignored until the mouse moves. This
    /// instead anchors a fixed-height band at the stable bottom edge and always
    /// extends it up to at least `maxBandHeight`, so a pointer resting anywhere a
    /// larger caption *would* occupy keeps registering steps across the whole
    /// 1..max range.
    public static func stableRegion(
        captionFrame: CGRect,
        maxBandHeight: CGFloat,
        horizontalInset: CGFloat = 0
    ) -> CGRect {
        let height = max(captionFrame.height, maxBandHeight)
        return CGRect(
            x: captionFrame.minX - horizontalInset,
            y: captionFrame.minY,
            width: captionFrame.width + horizontalInset * 2,
            height: height
        )
    }
}
