import AppKit
import Combine
import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// 中英互译路由：源为中文 → 英；否则 → 简中。
public enum TranslateRouting: Sendable {
    public struct Pair: Equatable, Sendable {
        public var source: Locale.Language?
        public var target: Locale.Language

        public init(source: Locale.Language?, target: Locale.Language) {
            self.source = source
            self.target = target
        }
    }

    public static func pair(for text: String) -> Pair {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .simplifiedChinese:
            return Pair(
                source: Locale.Language(identifier: "zh-Hans"),
                target: Locale.Language(identifier: "en")
            )
        case .traditionalChinese:
            return Pair(
                source: Locale.Language(identifier: "zh-Hant"),
                target: Locale.Language(identifier: "en")
            )
        case .english:
            return Pair(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans")
            )
        default:
            return Pair(
                source: nil,
                target: Locale.Language(identifier: "zh-Hans")
            )
        }
    }
}

public enum TranslateError: LocalizedError {
    case unsupported
    case notInstalled
    case failed

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "不支持"
        case .notInstalled: return "语言包未安装"
        case .failed: return "翻译失败"
        }
    }
}

/// 系统 Translation。语言包已装则可完全离线；未装时由系统决定是否下载。
@available(macOS 15.0, *)
@MainActor
public final class SystemTranslator {
    public static let shared = SystemTranslator()

    private let broker = TranslationBroker()
    private var hostPanel: NSPanel?

    private init() {}

    public func translate(_ texts: [String]) async throws -> [String] {
        let sample = texts.joined(separator: "\n")
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return texts
        }
        ensureHost()
        defer { hideHost() }
        let pair = TranslateRouting.pair(for: sample)
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let source = pair.source {
            status = await availability.status(from: source, to: pair.target)
        } else {
            status = try await availability.status(for: sample, to: pair.target)
        }
        switch status {
        case .unsupported:
            throw TranslateError.unsupported
        case .installed, .supported:
            break
        @unknown default:
            throw TranslateError.unsupported
        }
        do {
            return try await broker.translate(texts, source: pair.source, target: pair.target)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranslateError {
            throw error
        } catch {
            PinSnapLog.app.error("Translate: \(error.localizedDescription)")
            if status == .supported {
                throw TranslateError.notInstalled
            }
            throw TranslateError.failed
        }
    }

    private func ensureHost() {
        if let hostPanel {
            parkHost(hostPanel)
            hostPanel.orderFrontRegardless()
            return
        }
        let hosting = NSHostingView(rootView: TranslationBrokerView(broker: broker))
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let panel = NSPanel(
            contentRect: Self.hostFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .normal
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.contentView = hosting
        parkHost(panel)
        panel.orderFrontRegardless()
        hostPanel = panel
    }

    private func hideHost() {
        hostPanel?.orderOut(nil)
    }

    private static let hostFrame = NSRect(x: -20000, y: -20000, width: 1, height: 1)

    private func parkHost(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.setFrame(Self.hostFrame, display: false)
    }
}

@available(macOS 15.0, *)
@MainActor
final class TranslationBroker: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var generation = 0

    private var pending: Pending?

    private struct Pending {
        var texts: [String]
        var token: ResumeToken
    }

    private final class ResumeToken: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String], Error>?

        init(_ continuation: CheckedContinuation<[String], Error>) {
            self.continuation = continuation
        }

        func resume(returning value: [String]) {
            lock.lock()
            defer { lock.unlock() }
            continuation?.resume(returning: value)
            continuation = nil
        }

        func resume(throwing error: Error) {
            lock.lock()
            defer { lock.unlock() }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func translate(
        _ texts: [String],
        source: Locale.Language?,
        target: Locale.Language
    ) async throws -> [String] {
        pending?.token.resume(throwing: CancellationError())
        pending = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let token = ResumeToken(continuation)
                self.pending = Pending(texts: texts, token: token)
                self.generation += 1
                self.configuration = TranslationSession.Configuration(source: source, target: target)
            }
        } onCancel: {
            Task { @MainActor in
                self.pending?.token.resume(throwing: CancellationError())
                self.pending = nil
            }
        }
    }

    func handle(_ session: TranslationSession) async {
        guard let current = pending else { return }
        pending = nil
        do {
            try await session.prepareTranslation()
            let requests = current.texts.enumerated().compactMap { index, text -> TranslationSession.Request? in
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
            }
            guard !requests.isEmpty else {
                current.token.resume(returning: current.texts)
                return
            }
            let responses = try await session.translations(from: requests)
            var out = current.texts
            for response in responses {
                if let id = response.clientIdentifier, let i = Int(id), out.indices.contains(i) {
                    let t = response.targetText
                    if !t.isEmpty { out[i] = t }
                }
            }
            current.token.resume(returning: out)
        } catch {
            current.token.resume(throwing: error)
        }
    }
}

@available(macOS 15.0, *)
struct TranslationBrokerView: View {
    @ObservedObject var broker: TranslationBroker

    var body: some View {
        Color.clear
            .frame(width: 8, height: 8)
            .translationTask(broker.configuration) { session in
                await broker.handle(session)
            }
            .id(broker.generation)
    }
}
