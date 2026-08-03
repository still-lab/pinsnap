# 数据模型与状态

## Capture

```swift
struct ScreenID: Hashable, Codable { /* CGDirectDisplayID 包装 */ }

struct ScreenFrame {
    var screenID: ScreenID
    var logicalBounds: CGRect   // 全局逻辑坐标
    var scale: CGFloat
    var image: CGImage          // 像素尺寸 = logical * scale
}

struct CaptureSelection {
    var screenID: ScreenID
    var logicalRect: CGRect     // 相对该屏逻辑坐标或全局？→ 约定：全局逻辑点
}

enum CaptureSessionState: Equatable {
    case idle
    case preparing
    case capturing
    case annotating
    case committing
}
```

## Annotation

```swift
enum ShapeKind: String, Codable {
    case rect, ellipse, line, arrow, freehand, text, mosaic, blur
}

struct Shape: Identifiable, Codable {
    var id: UUID
    var kind: ShapeKind
    var strokeColor: CodableColor
    var fillColor: CodableColor?
    var lineWidth: CGFloat
    var points: [CGPoint]       // 像素空间，相对 baseImage
    var text: String?
}

struct AnnotationDocument: Codable {
    // base 图不进 Codable；另存文件
    var shapes: [Shape]
}
```

## Pin

```swift
enum PinLifecycleEvent {
    case create
    case close      // → closedStack
    case destroy    // 永久删
    case hideAll
    case showAll
    case restoreFromClosed
}

struct PinItem: Identifiable, Codable {
    var id: UUID
    var groupID: UUID?
    var frame: CGRect           // 全局逻辑
    var alpha: CGFloat
    var rotationDegrees: CGFloat
    var scale: CGFloat
    var ignoresMouse: Bool
    var imageFileName: String   // session 目录相对路径
}

struct PinSessionSnapshot: Codable {
    var version: Int            // = 1
    var pins: [PinItem]
    // v1.0 不做分组；保留字段兼容时可为空数组
    var groups: [PinGroup]
    var activeGroupID: UUID?
}
```

## Clipboard

```swift
enum ClipboardContent {
    case image(CGImage)
    case textRendered(CGImage)  // TextKit 离屏结果
    case colorCard(CGImage, hex: String)
}
```

## Feature

```swift
enum Feature: String, CaseIterable {
    case pinUnlimited
    // pinGroups — v1.0 不做
    case pinClickThrough
    // historyReplay — v1.0 不做
    case delayCapture
    case advancedAnnotate
    case filenameTemplate
}
```

## 持久化路径

```
~/Library/Containers/<bundle>/Data/Library/Application Support/PinSnap/
  settings.json          # 或 UserDefaults
  history/               # 成功截图缩略/原图（Pro）
  session/
    meta.json
    <uuid>.png
  bookmarks/             # 安全书签数据
```

## 内购商品 ID（规划，Connect 建档时保持一致）

| Product ID | 类型 |
|---|---|
| `app.pinsnap.pro.monthly` | 自动续期订阅 |
| `app.pinsnap.pro.yearly` | 自动续期订阅（可配 7 天试用） |
| `app.pinsnap.pro.lifetime` | 非消耗型 |
