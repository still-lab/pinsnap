import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ScreenPermissionStatus: Equatable, Sendable {
    case denied
    case grantedNeedsRelaunch
    case granted
}

/// 屏幕录制 TCC。授权绑定代码签名身份；adhoc 每次重签可能被当成新 App。
public enum ScreenPermission {
    private static var trustedAtLaunch: Bool?

    public static func noteLaunch() {
        if trustedAtLaunch == nil {
            trustedAtLaunch = CGPreflightScreenCaptureAccess()
        }
    }

    public static func status() -> ScreenPermissionStatus {
        noteLaunch()
        let now = CGPreflightScreenCaptureAccess()
        if !now { return .denied }
        return (trustedAtLaunch == true) ? .granted : .grantedNeedsRelaunch
    }

    public static func isReadyForCapture() -> Bool {
        status() == .granted
    }

    @discardableResult
    public static func requestAccess() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return CGRequestScreenCaptureAccess()
    }

    /// 截图前确保屏幕录制可用：未授权时弹出系统权限框；刚授权则重启 App；仍拒绝则可选深链设置。
    /// - Returns: `true` 表示可立即截帧；`false` 表示已拒绝、或正在重启。
    @MainActor
    public static func ensureReadyForCapture(openSettingsIfDenied: Bool) -> Bool {
        noteLaunch()
        switch status() {
        case .granted:
            return true
        case .grantedNeedsRelaunch:
            PinSnapLog.capture.info("screen recording granted; relaunching to apply TCC")
            relaunchApp()
            return false
        case .denied:
            let granted = requestAccess()
            if granted {
                // 多数系统版本需重启后 SCK 才生效；若本进程已可用则直接继续。
                if isReadyForCapture() {
                    return true
                }
                PinSnapLog.capture.info("screen recording just granted; relaunching")
                relaunchApp()
                return false
            }
            if openSettingsIfDenied {
                openSystemSettings()
            }
            PinSnapLog.capture.error("screen recording denied after system prompt")
            return false
        }
    }

    public static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    public static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    /// 调试：截帧探测结果写到 `/tmp/pinsnap-capture-test.txt`（不主动弹 TCC）。
    public static func writeCaptureSelfTestReport(to path: String = "/tmp/pinsnap-capture-test.txt") async {
        var lines: [String] = []
        lines.append("preflight=\(CGPreflightScreenCaptureAccess())")
        lines.append("bundle=\(Bundle.main.bundlePath)")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            lines.append("contentOK displays=\(content.displays.count) ids=\(content.displays.map(\.displayID))")
            let frames = try await CaptureService().captureStillFrames()
            lines.append("ok frames=\(frames.count)")
            for (i, f) in frames.enumerated() {
                lines.append("frame[\(i)] \(f.image.width)x\(f.image.height) screen=\(f.screenID.rawValue)")
            }
        } catch {
            let ns = error as NSError
            lines.append("error=\(error)")
            lines.append("domain=\(ns.domain) code=\(ns.code)")
            lines.append("localized=\(error.localizedDescription)")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
