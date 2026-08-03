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
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }

        var frames: [ScreenFrame] = []
        for screen in geometry.screens() {
            guard let display = content.displays.first(where: { $0.displayID == screen.id.rawValue }) else {
                continue
            }
            let image = try await captureDisplay(display, logicalFrame: screen.logicalFrame, scale: screen.scale)
            frames.append(ScreenFrame(
                screenID: screen.id,
                logicalBounds: screen.logicalFrame,
                scale: screen.scale,
                image: image
            ))
        }
        if frames.isEmpty {
            throw CaptureError.failed("未捕获到屏幕画面")
        }
        return frames
    }

    private func captureDisplay(_ display: SCDisplay, logicalFrame: CGRect, scale: CGFloat) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(logicalFrame.width * scale)
            config.height = Int(logicalFrame.height * scale)
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                throw CaptureError.failed(error.localizedDescription)
            }
        } else {
            let cgImage = CGWindowListCreateImage(
                logicalFrame,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution, .boundsIgnoreFraming]
            )
            guard let cgImage else {
                throw CaptureError.failed("截帧失败")
            }
            return cgImage
        }
    }
}

public enum ScreenPermission {
    public static func isTrusted() -> Bool {
        if #available(macOS 14.0, *) {
            // Best-effort: try sync probe via CG
            return CGPreflightScreenCaptureAccess()
        }
        return CGPreflightScreenCaptureAccess()
    }

    public static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
