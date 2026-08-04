# 实施状态（对照全覆盖计划）

更新：2026-08-04 — M0–M2 完成；M3 进行中。体验：菜单精简、延时菜单栏倒计时、取色双格式、放大镜、方向键微调。

## 阶段完成度

| 阶段 | 状态 | 说明 |
|---|---|---|
| B 前置 | 本地完成 / Ext 待你 | 法务页、商品 ID、图标、Connect 清单已备；需你在 Apple 账号完成登记 |
| C M0 | 完成 | Xcode App、LSUIElement、菜单栏、热键、屏幕权限深链（无引导窗）、设置壳 |
| D M1 | 完成 | ScreenGeometry、SCK/CG 截帧、窗口吸附、Overlay、复制/保存 |
| E M2 | 完成 | 标注含直线/模糊/撤销重做；Pin 滚轮缩放+空格滚轮透明度；截→贴 / 剪贴板贴图 / Free≤3 |
| F M3 | 进行中 | 见下方「M3 细项」 |
| G M4 | 未就绪 | 本地化/Connect/TestFlight 需账号侧 Ext |
| H 运营 | 流程文档 | CONNECT_SETUP / STORE_CHECKLIST 可跟踪 |
| I v1.1 | 代码落地 | `OCRService`（Vision 文本+条码） |
| J v1.2 | 骨架 | `AccessibilitySnap` 占位 + 文件名模板/导出扩展点 |
| K v1.3+ | 骨架 | `ScrollStitcher`、`ScreenRecorder` 骨架 |

## M3 细项

| 项 | 状态 |
|---|---|
| 关闭 / 销毁 / 隐藏全部 | 代码已有；`PIN_LIFECYCLE` 手工验收待勾 |
| 剪贴板文本 / 色卡贴图 | 代码已有；建议再验 |
| 延时截图（C-11） | **已完成**：菜单入口，固定 5s；菜单栏数字倒计时 |
| 上次区域（C-10） | **已完成**：状态栏菜单 + 内存选区；热键暂缓 |
| FeatureGate ↔ StoreKit 沙盒 | 客户端骨架有；`isEnabled` 仍全开，真门控未接 |
| 取色 HEX/RGB（C-09） | **已完成**：双格式色卡；C 复制 / Tab 切换 |
| 放大镜（C-08） | **已完成**：仅取色模式显示 |
| 选区方向键微调（C-07） | **已完成**：←↑↓→，Shift 步进 10 |
| 记号笔 / 橡皮（笔子菜单） | **已完成** |
| 菜单栏图标 | **已换**：MenuBarIcon 模板图；左键仅菜单 |
| 自动保存 / 光标下窗口等 P1 | 待做 |
| 旋转镜像 / 缩略图 / 贴图上标注 | 待做 |
| 工具条热键 | **暂缓**统一规划 |
| 设置深接线（开机启动等） | **暂缓**合理规划后再做 |
| 穿透 / 分组 / 历史 / 会话恢复 / 捕捉光标 | **不做或暂缓**（已决议） |

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
