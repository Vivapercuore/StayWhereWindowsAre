import CoreGraphics
import Foundation

enum FrameResolver {
    /// Where a saved window should go on the current displays, or nil when its display is not connected.
    static func targetFrame(for record: WindowRecord, in displays: [DisplayInfo]) -> (frame: CGRect, display: DisplayInfo)? {
        if let uuid = record.displayUUID, let display = displays.first(where: { $0.uuid == uuid }), let relative = record.relativeFrame {
            if let savedSize = record.displaySize, savedSize.width > 0, savedSize.height > 0,
               abs(savedSize.width - display.frame.width) > 1 || abs(savedSize.height - display.frame.height) > 1 {
                let sx = display.frame.width / savedSize.width
                let sy = display.frame.height / savedSize.height
                let scaled = CGRect(
                    x: display.frame.minX + relative.minX * sx,
                    y: display.frame.minY + relative.minY * sy,
                    width: relative.width * sx,
                    height: relative.height * sy)
                return (clamp(scaled, to: display.visibleFrame).integral, display)
            }
            return (relative.offsetBy(dx: display.frame.minX, dy: display.frame.minY), display)
        }
        guard record.displayUUID == nil || record.relativeFrame == nil,
              let display = display(containing: record.frame, in: displays),
              display.frame.intersects(record.frame) else { return nil }
        return (record.frame, display)
    }

    /// Keeps the window inside the visible area, shrinking it if it does not fit.
    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        guard !visible.isEmpty else { return frame }
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    /// The display a frame mostly lies on, falling back to the display nearest to its center.
    static func display(containing frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: DisplayInfo?
        var bestArea: CGFloat = 0
        for display in displays {
            let overlap = display.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = display
                bestArea = area
            }
        }
        if let best { return best }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { distance(from: center, to: $0.frame) < distance(from: center, to: $1.frame) }
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func relativeFrame(of frame: CGRect, on display: DisplayInfo) -> CGRect {
        frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    /// Whether a window counts as being at its target. Size gets more slack than position because apps round
    /// sizes to their own grid (terminal cells, minimum sizes). Used both to decide whether a window needs
    /// moving and whether a move succeeded, so a window that cannot reach the exact size is not moved forever.
    static func isAtTarget(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.minX - target.minX) <= 6 && abs(actual.minY - target.minY) <= 6
            && abs(actual.width - target.width) <= 16 && abs(actual.height - target.height) <= 16
    }

    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// A frame fully inside `display`, used to park a window there for a moment while it changes Space.
    static func parkingFrame(for size: CGSize, on display: DisplayInfo) -> CGRect {
        let area = display.visibleFrame.isEmpty ? display.frame : display.visibleFrame
        let width = min(size.width, area.width * 0.8)
        let height = min(size.height, area.height * 0.8)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
    }
}
