# 编码约定

## 语言与平台

- Swift 5.9+，严格模式（尽量避免强制解包；必要时 `precondition` 写清不变量）。
- UI：截图/贴图/Overlay 用 **AppKit**；设置/引导/商店页用 **SwiftUI**。
- 最低部署：macOS 13。

## 命名

- 类型：UpperCamelCase。
- 方法/属性：lowerCamelCase。
- 需求追溯：实现旁注释可用 `// REQ: C-01` 或测试名含 ID。
- 文件名与主类型同名：`PinStore.swift`。

## 模块边界

- 新功能先问：归属哪个模块？禁止为图方便在 App 里堆业务。
- 跨模块只依赖 **公开协议/结构体**，不依赖对方 `internal` 实现细节（同 target 时仍按目录自律）。
- `import ScreenCaptureKit` 仅允许出现在 `Capture/`。

## 异步

- 优先 `async/await`。
- UI 更新：`@MainActor` 标注 Controller。
- 不要在主线程做 CI 重滤镜或大图 JPEG 编码。

## 错误

- 领域错误用 `enum XxxError: LocalizedError`。
- 用户可见：Toast / 设置页红字；日志打 `os.Logger`（subsystem `app.pinsnap.macos`）。

## 资源与文案

- 用户可见字符串进 `Localizable.xcstrings`（中/英）。
- 界面文案保持短标签；不写解释性免责长文（产品约定）。

## Git

- Conventional commits：`feat` / `fix` / `chore` / `docs` / `refactor` / `test`。
- 不提交密钥、证书、`xcuserdata`。

## 测试

- 几何、剪贴板、Pin 状态机、FeatureGate **必须**有单测。
- UI 以手工清单为主（见 MILESTONES）。

## 禁止

- 私有 API、擅自关掉沙盒「先跑通再说」。
- 默认收集分析数据。
- 在 v1.0 引入网络图床/账号体系。
