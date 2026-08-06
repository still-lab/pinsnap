import AppKit
import Foundation
import UniformTypeIdentifiers

/// 保存目录书签与格式偏好。REQ: C-15 / E-02 / E-04
@MainActor
public enum SaveDirectoryKind {
    case defaultSave
    case quickSave

    fileprivate var bookmarkKey: String {
        switch self {
        case .defaultSave: return "pinsnap.defaultSaveDirectory"
        case .quickSave: return "pinsnap.quickSaveDirectory"
        }
    }
}

@MainActor
public enum SavePreferences {
    public static let formatKey = "pinsnap.saveFormat"
    public static let templateKey = "pinsnap.filenameTemplate"

    public static var saveFormat: ImageFormat {
        get {
            let raw = UserDefaults.standard.string(forKey: formatKey) ?? ImageFormat.png.rawValue
            return ImageFormat(rawValue: raw) ?? .png
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: formatKey)
        }
    }

    public static var filenameTemplate: FilenameTemplate {
        let pattern = UserDefaults.standard.string(forKey: templateKey) ?? FilenameTemplate.default.pattern
        return FilenameTemplate(pattern: pattern)
    }

    public static func resolveDirectory(_ kind: SaveDirectoryKind) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: kind.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale {
            storeBookmark(for: url, kind: kind)
        }
        return url
    }

    /// 快捷保存目录 → 默认目录 → nil。
    public static func resolveQuickSaveDirectory() -> URL? {
        resolveDirectory(.quickSave) ?? resolveDirectory(.defaultSave)
    }

    public static func displayPath(for kind: SaveDirectoryKind) -> String {
        guard let url = resolveDirectory(kind) else { return "未选择" }
        return url.path
    }

    public static func setDirectory(_ url: URL, kind: SaveDirectoryKind) {
        storeBookmark(for: url, kind: kind)
    }

    /// 弹出选目录面板；成功则写入书签并返回 URL。
    public static func pickDirectory(kind: SaveDirectoryKind) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if let existing = resolveDirectory(kind) {
            panel.directoryURL = existing
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setDirectory(url, kind: kind)
        return url
    }

    public static func fileExtension(for format: ImageFormat) -> String {
        format == .png ? "png" : "jpg"
    }

    public static func contentType(for format: ImageFormat) -> UTType {
        format == .png ? .png : .jpeg
    }

    public static func suggestedFileName(width: Int, height: Int, format: ImageFormat) -> String {
        filenameTemplate.render(width: width, height: height) + "." + fileExtension(for: format)
    }

    public static func makeUniqueFileURL(in directory: URL, width: Int, height: Int, format: ImageFormat) -> URL {
        let name = suggestedFileName(width: width, height: height, format: format)
        var url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let base = filenameTemplate.render(width: width, height: height)
        let ext = fileExtension(for: format)
        for i in 2...999 {
            url = directory.appendingPathComponent("\(base)-\(i).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    public static func withSecurityScopedAccess<T>(to directory: URL, _ body: () throws -> T) rethrows -> T {
        let accessed = directory.startAccessingSecurityScopedResource()
        defer {
            if accessed { directory.stopAccessingSecurityScopedResource() }
        }
        return try body()
    }

    public static func openDefaultDirectoryInFinder() {
        let dir = resolveDirectory(.defaultSave)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let bookmarked = resolveDirectory(.defaultSave) {
            _ = withSecurityScopedAccess(to: bookmarked) {
                NSWorkspace.shared.open(bookmarked)
            }
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    private static func storeBookmark(for url: URL, kind: SaveDirectoryKind) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: kind.bookmarkKey)
        } catch {
            PinSnapLog.app.error("save bookmark: \(error.localizedDescription)")
        }
    }
}
