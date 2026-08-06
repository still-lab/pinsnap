# 模块规划

## 目录 ↔ 模块

| 目录 | 模块名 | 职责 |
|---|---|---|
| `Sources/PinSnap/App` | AppShell | `@main`、MenuBar、HotKeyCenter、SessionCoordinator |
| `Sources/PinSnap/Capture` | CaptureKit | ScreenGeometry、CaptureService、WindowTracker、ScreenshotFrame |
| `Sources/PinSnap/Overlay` | OverlayUI | CaptureOverlayPanel、SelectionView、MagnifierView、CaptureToolbar |
| `Sources/PinSnap/Annotate` | Annotator | AnnotationDocument、Shape、Renderer、UndoCommands |
| `Sources/PinSnap/Pin` | PinBoard | PinStore、PinPanelController、PinSessionCoder、ClipboardBridge |
| `Sources/PinSnap/Export` | Export | ImageExporter、FilenameTemplate、SavePreferences |
| `Sources/PinSnap/Purchase` | Purchase | StoreClient、FeatureGate、EntitlementSync |
| `Sources/PinSnap/Settings` | Settings | SwiftUI Settings scene |
| `Sources/PinSnap/Support` | Support | Logger、Toast、AtomicFile、Result 扩展 |

## 依赖（允许方向）

```
App → Capture, Overlay, Annotate, Pin, Export, Purchase, Settings, Support
Overlay → Capture, Annotate, Support
Pin → Annotate, Purchase, Support
Export → Support
Capture → Support
Purchase → Support
Settings → Purchase, Support
```

**禁止：** Overlay/Pin/Settings → ScreenCaptureKit 直接 import。  
**禁止：** Capture → Overlay / Pin（反向依赖）。

## 各模块公开面（规划）

### App

- `SessionCoordinator`：驱动截图状态机；组装出口。
- `HotKeyCenter`：按 `HotKeyPreferences` 注册；截图键连击派发上次区域。
- `ScreenPermission`：TCC 状态检测与系统设置深链（无自定义引导窗）。

### Capture

- `ScreenGeometry`：屏列表、点↔像素、screenID。
- `CaptureService`：`captureStillFrames() async throws -> [ScreenFrame]`。
- `WindowTracker`：`windowRects(at: CGPoint) -> [WindowHit]`。

### Overlay

- 仅展示与收集 `CaptureSelection`；确认后回调 Coordinator。

### Annotate

- `AnnotationDocument` 值类型 + `AnnotationController`。
- `exportFlattened() -> CGImage`。

### Pin

- `PinStore`：`create` / `close` / `destroy` / `hideAll`（v1.0 不做 `restoreSession`）。
- `ClipboardBridge.resolve() -> ClipboardContent`。
- Free：`create` 前查 `FeatureGate`。

### Purchase

- `Feature` 枚举 + `FeatureGate.isEnabled(_:)`。
- StoreKit 2 商品 ID（规划）：
  - `app.pinsnap.pro.monthly`
  - `app.pinsnap.pro.yearly`
  - `app.pinsnap.pro.lifetime`

### Export

- `SavePreferences`：默认/快捷目录书签、png/jpeg、文件名模板。
- PNG 默认；JPEG 质量可配；目录书签 security-scoped。

## 测试映射

| 测试目标 | 目录 |
|---|---|
| 几何换算 | `Tests/.../ScreenGeometryTests` |
| 剪贴板解析 | `ClipboardBridgeTests` |
| Pin 生命周期 | `PinStoreTests` |
| Feature 边界 | `FeatureGateTests` |
| Undo | `AnnotationUndoTests` |
