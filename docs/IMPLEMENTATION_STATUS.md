# 实施状态（对照全覆盖计划）

更新：本地工程已可 `xcodegen` + `xcodebuild` 构建成功。

## 阶段完成度

| 阶段 | 状态 | 说明 |
|---|---|---|
| B 前置 | 本地完成 / Ext 待你 | 法务页、商品 ID、图标、Connect 清单已备；需你在 Apple 账号完成登记 |
| C M0 | 完成 | Xcode App、LSUIElement、菜单栏、热键、屏幕权限深链（无引导窗）、设置壳 |
| D M1 | 完成 | ScreenGeometry、SCK/CG 截帧、窗口吸附、Overlay、复制/保存 |
| E M2 | 主体 | 标注主路径、Pin 窗口、剪贴板贴图、Free≤3、升级页；线/模糊/透明度等可打磨 |
| F M3 | 进行中 | 关闭/销毁/显隐、穿透、会话、StoreKit 客户端；**不做**分组/历史；延时等 P1 待补 |
| G M4 | 未就绪 | 本地化/Connect/TestFlight 需账号侧 Ext |
| H 运营 | 流程文档 | CONNECT_SETUP / STORE_CHECKLIST 可跟踪 |
| I v1.1 | 代码落地 | `OCRService`（Vision 文本+条码） |
| J v1.2 | 骨架 | `AccessibilitySnap` 占位 + 文件名模板/导出扩展点 |
| K v1.3+ | 骨架 | `ScrollStitcher`、`ScreenRecorder` 骨架 |

## 如何运行

```bash
cd /Users/huihui/PinSnap
xcodegen generate
open PinSnap.xcodeproj
# 或
xcodebuild -scheme PinSnap -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/PinSnap.app
```

首次截图需在「系统设置 → 隐私与安全性 → 屏幕录制」勾选 PinSnap。

## 测试

```bash
swift test
```

## 仍须人工 Ext

见 [`docs/CONNECT_SETUP.md`](CONNECT_SETUP.md)：Developer、Connect App、内购三档、隐私 URL 托管、提审。
