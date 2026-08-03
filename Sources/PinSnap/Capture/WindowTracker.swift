import AppKit
import CoreGraphics
import Foundation

/// 窗口级命中（非 AX 元素）。REQ: C-02
public protocol WindowTrackerProtocol: Sendable {
    func hits(at globalPoint: CGPoint) -> [WindowHit]
    func hit(at globalPoint: CGPoint) -> WindowHit?
}

public struct WindowTracker: WindowTrackerProtocol {
    public init() {}

    public func hits(at globalPoint: CGPoint) -> [WindowHit] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var results: [WindowHit] = []
        for entry in info {
            guard
                let windowID = entry[kCGWindowNumber as String] as? UInt32,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let layer = entry[kCGWindowLayer as String] as? Int,
                layer == 0
            else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            // CGWindow bounds are top-left origin in global display space; convert to Cocoa bottom-left
            let cocoa = cgToCocoa(bounds)
            guard cocoa.contains(globalPoint) else { continue }
            let name = (entry[kCGWindowName as String] as? String)
                ?? (entry[kCGWindowOwnerName as String] as? String)
                ?? ""
            results.append(WindowHit(windowID: windowID, logicalBounds: cocoa, name: name))
        }
        return results
    }

    public func hit(at globalPoint: CGPoint) -> WindowHit? {
        hits(at: globalPoint).first
    }

    private func cgToCocoa(_ rect: CGRect) -> CGRect {
        // CG global: origin top-left of main display; Cocoa: origin bottom-left of main
        guard let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return rect
        }
        let screenHeight = main.frame.height
        return CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
