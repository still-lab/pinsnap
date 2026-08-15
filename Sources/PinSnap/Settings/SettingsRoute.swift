import AppKit
import SwiftUI

/// 设置侧栏：通用 / 快捷键 / 存储 / 关于。Pro 搁置。
public enum SettingsRoute: String, Sendable, CaseIterable, Identifiable, Hashable {
    case general, hotkeys, save, about
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "通用"
        case .hotkeys: return "快捷键"
        case .save: return "存储"
        case .about: return "关于"
        }
    }
}

public struct SettingsRootView: View {
    @State private var route: SettingsRoute = .general

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            List(SettingsRoute.allCases, selection: $route) { r in
                Text(r.title)
                    .tag(r)
                    .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .frame(width: 132)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch route {
                case .general:
                    GeneralSettingsPage()
                case .hotkeys:
                    HotKeysSettingsPage()
                case .save:
                    SaveSettingsPage()
                case .about:
                    AboutSettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - Pages

private struct GeneralSettingsPage: View {
    @AppStorage(ColorValueFormat.defaultsKey) private var colorFormat = ColorValueFormat.hex.rawValue
    @AppStorage(AppBootstrap.hotKeysDisabledDefaultsKey) private var hotKeysDisabled = true
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        Form {
            Section {
                Toggle(
                    "开机启动",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .padding(.vertical, 6)

                Picker("取色格式", selection: $colorFormat) {
                    Text("HEX").tag(ColorValueFormat.hex.rawValue)
                    Text("RGB").tag(ColorValueFormat.rgb.rawValue)
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 6)

                Toggle(
                    "禁用快捷键",
                    isOn: Binding(
                        get: { hotKeysDisabled },
                        set: { newValue in
                            hotKeysDisabled = newValue
                            AppBootstrap.shared.setHotKeysDisabled(newValue)
                        }
                    )
                )
                .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hotKeysDisabled = AppBootstrap.shared.hotKeysDisabled
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}

private struct HotKeysSettingsPage: View {
    @ObservedObject private var prefs = HotKeyPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Form {
                Section {
                    ForEach(orderedGlobalRows, id: \.id) { row in
                        hotkeyRow(row)
                            .padding(.vertical, 4)
                    }
                } header: {
                    Text("全局")
                }

                Section {
                    ForEach(HotKeySlot.overlaySlots) { slot in
                        hotkeyRow(.editable(slot))
                            .padding(.vertical, 4)
                    }
                    LabeledContent("选区微调") {
                        Text("←↑↓→")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 72, alignment: .center)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("截图中")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("恢复默认") {
                    prefs.resetToDefaults()
                }
            }
        }
    }

    private enum Row: Identifiable {
        case editable(HotKeySlot)
        case lastRegion

        var id: String {
            switch self {
            case .editable(let s): return s.rawValue
            case .lastRegion: return "lastRegion"
            }
        }
    }

    private var orderedGlobalRows: [Row] {
        [.editable(.capture), .lastRegion, .editable(.delayedCapture), .editable(.paste), .editable(.hidePins), .editable(.showPins)]
    }

    @ViewBuilder
    private func hotkeyRow(_ row: Row) -> some View {
        switch row {
        case .editable(let slot):
            HStack(alignment: .center, spacing: 12) {
                Text(slot.title)
                Spacer(minLength: 8)
                if prefs.isConflicted(slot) {
                    Text("冲突")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HotKeyRecorderControl(slot: slot)
            }
        case .lastRegion:
            LabeledContent("上次区域") {
                Text(prefs.lastRegionDisplayString)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .center)
            }
        }
    }
}

private struct SaveSettingsPage: View {
    @AppStorage(SavePreferences.templateKey) private var template = FilenameTemplate.default.pattern
    @AppStorage(SavePreferences.formatKey) private var saveFormat = ImageFormat.png.rawValue
    @State private var defaultPath = SavePreferences.displayPath(for: .defaultSave)
    @State private var quickPath = SavePreferences.displayPath(for: .quickSave)

    var body: some View {
        Form {
            Section {
                directoryRow(title: "默认文件夹", path: defaultPath) {
                    if SavePreferences.pickDirectory(kind: .defaultSave) != nil {
                        defaultPath = SavePreferences.displayPath(for: .defaultSave)
                    }
                }
                .padding(.vertical, 4)

                directoryRow(title: "快捷保存文件夹", path: quickPath) {
                    if SavePreferences.pickDirectory(kind: .quickSave) != nil {
                        quickPath = SavePreferences.displayPath(for: .quickSave)
                    }
                }
                .padding(.vertical, 4)

                Picker("格式", selection: $saveFormat) {
                    Text("PNG").tag(ImageFormat.png.rawValue)
                    Text("JPEG").tag(ImageFormat.jpeg.rawValue)
                }
                .padding(.vertical, 6)

                TextField("文件名模板", text: $template)
                    .padding(.vertical, 6)
            }

            Section {
                Button("打开保存目录") {
                    SavePreferences.openDefaultDirectoryInFinder()
                }
                .padding(.vertical, 4)
                Button("清空上次区域") {
                    AppBootstrap.shared.coordinator.clearCaptureHistory()
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            defaultPath = SavePreferences.displayPath(for: .defaultSave)
            quickPath = SavePreferences.displayPath(for: .quickSave)
        }
    }

    private func directoryRow(title: String, path: String, pick: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("选择…", action: pick)
        }
    }
}

private struct AboutSettingsPage: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .padding(.vertical, 6)
                Link("隐私政策", destination: URL(string: "https://example.com/pinsnap/privacy")!)
                    .padding(.vertical, 4)
                Link("使用条款", destination: URL(string: "https://example.com/pinsnap/terms")!)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
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
