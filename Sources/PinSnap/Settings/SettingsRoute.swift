import AppKit
import SwiftUI

public enum SettingsRoute: String, Sendable, CaseIterable, Identifiable, Hashable {
    case general, hotkeys, save, purchase, about
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "通用"
        case .hotkeys: return "快捷键"
        case .save: return "存储"
        case .purchase: return "Pro"
        case .about: return "关于"
        }
    }
}

public struct SettingsRootView: View {
    @State private var route: SettingsRoute = .general
    @AppStorage(ColorValueFormat.defaultsKey) private var colorFormat = ColorValueFormat.hex.rawValue
    @AppStorage("pinsnap.filenameTemplate") private var template = FilenameTemplate.default.pattern

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            List(SettingsRoute.allCases, selection: $route) { r in
                Text(r.title).tag(r)
            }
            .frame(width: 120)
            Group {
                switch route {
                case .general:
                    Form {
                        Picker("取色格式", selection: $colorFormat) {
                            Text("HEX").tag(ColorValueFormat.hex.rawValue)
                            Text("RGB").tag(ColorValueFormat.rgb.rawValue)
                        }
                    }
                case .hotkeys:
                    Form {
                        LabeledContent("截图", value: "F1")
                        LabeledContent("延时截图", value: "⌘T")
                        LabeledContent("上次区域", value: "F1×2")
                        LabeledContent("贴图", value: "F3")
                        LabeledContent("隐藏贴图", value: "⌘H")
                        LabeledContent("显示贴图", value: "⌘⇧H")
                        LabeledContent("取色复制", value: "C")
                        LabeledContent("取色切换", value: "Tab")
                        LabeledContent("选区微调", value: "←↑↓→")
                    }
                case .save:
                    Form {
                        TextField("文件名模板", text: $template)
                        Button("打开保存目录") {
                            AppBootstrap.shared.coordinator.openLastSaveDirectory()
                        }
                        Button("清空上次区域") {
                            AppBootstrap.shared.coordinator.clearCaptureHistory()
                        }
                    }
                case .purchase:
                    UpgradeView()
                case .about:
                    Form {
                        LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        Link("隐私政策", destination: URL(string: "https://example.com/pinsnap/privacy")!)
                        Link("使用条款", destination: URL(string: "https://example.com/pinsnap/terms")!)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        }
        .frame(width: 460, height: 320)
    }
}

public struct UpgradeView: View {
    @State private var productsLoaded = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PinSnap Pro").font(.title2.bold())
            Text("· 无限贴图\n· OCR 与进阶能力").font(.body)
            HStack {
                Button("¥8/月") { Task { await buy(StoreProductID.monthly) } }
                Button("¥48/年") { Task { await buy(StoreProductID.yearly) } }
                Button("¥98 买断") { Task { await buy(StoreProductID.lifetime) } }
            }
            Button("恢复购买") {
                Task { try? await StoreClient.shared.restore() }
            }
            if FeatureGate.shared.isPro {
                Text("已解锁 Pro").foregroundStyle(.green)
            }
        }
        .padding()
        .task {
            await StoreClient.shared.loadProducts()
            productsLoaded = true
        }
    }

    private func buy(_ id: String) async {
        await StoreClient.shared.loadProducts()
        if let p = StoreClient.shared.products.first(where: { $0.id == id }) {
            try? await StoreClient.shared.purchase(p)
        } else {
            #if DEBUG
            FeatureGate.shared.debugForcePro = true
            FeatureGate.shared.applyEntitlement(isPro: true)
            #endif
        }
    }
}
