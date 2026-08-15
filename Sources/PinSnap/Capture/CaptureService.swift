import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 截帧服务。唯一允许深度使用 ScreenCaptureKit 的入口。
/// REQ: C-01–C-03
public protocol CaptureServiceProtocol: Sendable {
    func captureStillFrames() async throws -> [ScreenFrame]
    /// 按选区截取一帧（像素）；`excludingWindowIDs` 用于去掉长截 HUD / 遮罩窗。
    func captureRegion(_ selection: CaptureSelection, excludingWindowIDs: [CGWindowID]) async throws -> CGImage
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
        let content = try await shareableContent()
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
                // 单屏截帧失败不拖垮整次截图：跳过该屏，继续采集其它屏。
                PinSnapLog.capture.error("captureDisplay failed for screen \(screen.id.rawValue): \(error.localizedDescription)")
                continue
            }
        }

        if frames.isEmpty {
            throw CaptureError.failed("未匹配到可截取的显示器")
        }
        return frames
    }

    public func captureRegion(
        _ selection: CaptureSelection,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage {
        // ScreenGeometry 读 NSScreen，必须在主线程
        let screen: ScreenDescriptor = try await MainActor.run {
            guard let s = geometry.screen(id: selection.screenID) else {
                throw CaptureError.failed("选区屏幕无效")
            }
            return s
        }
        let cocoaRect = selection.logicalRect
        guard cocoaRect.width >= 2, cocoaRect.height >= 2 else {
            throw CaptureError.failed("选区过小")
        }
        // CGWindowListCreateImage 使用 CG 全局坐标（主屏左上原点），选区是 Cocoa 坐标
        let rect = await MainActor.run { ScreenGeometry.cocoaToCGWindowRect(cocoaRect) }

        // 遮罩已 orderOut：先走快路径 CG；失败再整屏 SCK 裁剪。
        let below = excludingWindowIDs.first ?? kCGNullWindowID
        let listOption: CGWindowListOption = below == kCGNullWindowID
            ? .optionOnScreenOnly
            : .optionOnScreenBelowWindow
        if let image = CGWindowListCreateImage(
            rect,
            listOption,
            below,
            [.bestResolution, .boundsIgnoreFraming]
        ), Self.imageHasOpaqueContent(image) {
            PinSnapLog.capture.info(
                "captureRegion CG \(image.width)x\(image.height) cocoaY=\(Int(cocoaRect.minY)) cgY=\(Int(rect.minY))"
            )
            return image
        }

        if below != kCGNullWindowID,
           let image = CGWindowListCreateImage(
                rect,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution, .boundsIgnoreFraming]
           ),
           Self.imageHasOpaqueContent(image)
        {
            PinSnapLog.capture.info("captureRegion CG onScreen \(image.width)x\(image.height)")
            return image
        }

        if #available(macOS 14.0, *) {
            do {
                let image = try await captureRegionByDisplayCrop(
                    selection,
                    screen: screen,
                    excludingWindowIDs: excludingWindowIDs
                )
                if Self.imageHasOpaqueContent(image) {
                    return image
                }
                PinSnapLog.capture.error(
                    "captureRegion crop empty \(image.width)x\(image.height)"
                )
            } catch CaptureError.permissionDenied {
                throw CaptureError.permissionDenied
            } catch {
                PinSnapLog.capture.error("captureRegion SCK crop: \(error.localizedDescription)")
            }
        }

        throw CaptureError.failed("选区截帧失败")
    }

    @available(macOS 14.0, *)
    private func captureRegionByDisplayCrop(
        _ selection: CaptureSelection,
        screen: ScreenDescriptor,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = Self.matchDisplay(screen: screen, in: content.displays) else {
            throw CaptureError.failed("未匹配到显示器")
        }
        let excluded = content.windows.filter { excludingWindowIDs.contains(CGWindowID($0.windowID)) }
        let full = try await captureDisplay(
            display,
            logicalFrame: screen.logicalFrame,
            scale: screen.scale,
            excludingWindows: excluded
        )
        let originInScreen = CGPoint(
            x: selection.logicalRect.minX - screen.logicalFrame.minX,
            y: selection.logicalRect.minY - screen.logicalFrame.minY
        )
        let pixelRect = CGRect(
            x: originInScreen.x * screen.scale,
            y: originInScreen.y * screen.scale,
            width: selection.logicalRect.width * screen.scale,
            height: selection.logicalRect.height * screen.scale
        )
        let flipped = CGRect(
            x: pixelRect.origin.x,
            y: CGFloat(full.height) - pixelRect.origin.y - pixelRect.height,
            width: pixelRect.width,
            height: pixelRect.height
        ).integral
        guard let cropped = full.cropping(to: flipped), cropped.width > 1, cropped.height > 1 else {
            throw CaptureError.failed("区域裁剪失败")
        }
        PinSnapLog.capture.info("captureRegion crop \(cropped.width)x\(cropped.height)")
        return cropped
    }

    /// CG / SCK 偶发返回全透明空帧。
    static func imageHasOpaqueContent(_ image: CGImage) -> Bool {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return false }
        let sw = min(32, w)
        let sh = min(32, h)
        var pixels = [UInt8](repeating: 0, count: sw * sh * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: sw,
            height: sh,
            bitsPerComponent: 8,
            bytesPerRow: sw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var opaque = 0
        var i = 0
        while i < pixels.count {
            if pixels[i + 3] > 8 { opaque += 1 }
            i += 4
        }
        return opaque > (sw * sh) / 20
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("deny") || text.contains("denied") || text.contains("not authorized")
            || text.contains("permission") || text.contains("tcc") || text.contains("授权")
        {
            return true
        }
        if error.domain.contains("ScreenCapture") || error.domain.contains("SCStream") {
            return error.code == -3801 || error.code == -3802 || error.code == 1002
        }
        return false
    }

    private static func matchDisplay(screen: ScreenDescriptor, in displays: [SCDisplay]) -> SCDisplay? {
        if let exact = displays.first(where: { $0.displayID == screen.id.rawValue }) {
            return exact
        }
        if displays.count == 1 { return displays[0] }
        return nil
    }

    private func captureDisplay(
        _ display: SCDisplay,
        logicalFrame: CGRect,
        scale: CGFloat,
        excludingWindows: [SCWindow] = []
    ) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
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
