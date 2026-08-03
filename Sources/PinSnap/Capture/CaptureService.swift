import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 截帧服务。唯一允许深度使用 ScreenCaptureKit 的入口。
/// REQ: C-01–C-03
public protocol CaptureServiceProtocol: Sendable {
    func captureStillFrames() async throws -> [ScreenFrame]
}

public enum CaptureError: Error, LocalizedError, Sendable {
    case permissionDenied
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要屏幕录制权限才能截图"
        case .cancelled: return "已取消"
        case .failed(let message): return message
        }
    }
}

public struct CaptureService: CaptureServiceProtocol {
    private let geometry: ScreenGeometry

    public init(geometry: ScreenGeometry = ScreenGeometry()) {
        self.geometry = geometry
    }

    public func captureStillFrames() async throws -> [ScreenFrame] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            let ns = error as NSError
            PinSnapLog.capture.error(
                "SCShareableContent domain=\(ns.domain) code=\(ns.code) \(error.localizedDescription)"
            )
            if Self.isPermissionError(ns) {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.failed(error.localizedDescription)
        }

        PinSnapLog.capture.info(
            "SCK displays=\(content.displays.count) screens=\(self.geometry.screens().count)"
        )

        var frames: [ScreenFrame] = []
        let screens = geometry.screens()
        for screen in screens {
            guard let display = Self.matchDisplay(screen: screen, in: content.displays) else {
                PinSnapLog.capture.error(
                    "no SCDisplay for screen \(screen.id.rawValue); available=\(content.displays.map(\.displayID))"
                )
                continue
            }
            do {
                let image = try await captureDisplay(
                    display,
                    logicalFrame: screen.logicalFrame,
                    scale: screen.scale
                )
                frames.append(ScreenFrame(
                    screenID: screen.id,
                    logicalBounds: screen.logicalFrame,
                    scale: screen.scale,
                    image: image
                ))
            } catch {
                PinSnapLog.capture.error("captureDisplay failed: \(error.localizedDescription)")
                throw error
            }
        }

        if frames.isEmpty {
            throw CaptureError.failed("未匹配到可截取的显示器")
        }
        return frames
    }

    private static func matchDisplay(screen: ScreenDescriptor, in displays: [SCDisplay]) -> SCDisplay? {
        if let exact = displays.first(where: { $0.displayID == screen.id.rawValue }) {
            return exact
        }
        // 单屏容错：ID 偶发不一致时仍可截
        if displays.count == 1 { return displays[0] }
        return nil
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("deny") || text.contains("denied") || text.contains("not authorized")
            || text.contains("permission") || text.contains("tcc") || text.contains("授权")
        {
            return true
        }
        // ScreenCaptureKit / CoreGraphics 常见权限码（不同系统版本不完全稳定）
        if error.domain.contains("ScreenCapture") || error.domain.contains("SCStream") {
            return error.code == -3801 || error.code == -3802 || error.code == 1002
        }
        return false
    }

    private func captureDisplay(_ display: SCDisplay, logicalFrame: CGRect, scale: CGFloat) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = max(1, Int((logicalFrame.width * scale).rounded()))
            config.height = max(1, Int((logicalFrame.height * scale).rounded()))
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.captureResolution = .best
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                let ns = error as NSError
                PinSnapLog.capture.error(
                    "SCScreenshotManager domain=\(ns.domain) code=\(ns.code) \(error.localizedDescription)"
                )
                if Self.isPermissionError(ns) {
                    throw CaptureError.permissionDenied
                }
                throw CaptureError.failed(error.localizedDescription)
            }
        } else {
            guard let cgImage = CGWindowListCreateImage(
                logicalFrame,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) else {
                throw CaptureError.failed("截帧失败")
            }
            return cgImage
        }
    }
}
