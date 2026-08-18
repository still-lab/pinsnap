# 实施状态（对照全覆盖计划）

更新：2026-08-18 — 最低系统抬至 macOS 15；系统 Translation 已接 OCR 出口。

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
| I v1.1 | 代码落地 | `OCRService`（Vision 文本+条码）；系统 Translation（工具条「译」，语言包已装可离线） |
| J v1.2 | 骨架 | `AccessibilitySnap` 占位 + 文件名模板/导出扩展点 |
| K v1.3+ | 进行中 | 长截：`captureRegion` + `ScrollStitcher` 条带对齐 + Overlay 滚动态；录屏仍为骨架 |

## M3 细项

| 项 | 状态 |
|---|---|
| 关闭 / 销毁 / 隐藏全部 / 恢复最近关闭 | 代码已有：关闭进栈（容量 5）、菜单「恢复最近关闭」已接线；`PIN_LIFECYCLE` 手工验收待勾 |
| 剪贴板文本 / 色卡贴图 | 代码已有；建议再验 |
| 延时截图（C-11） | **已完成**：菜单入口，固定 5s；菜单栏数字倒计时 |
| 上次区域（C-10） | **已完成**：状态栏菜单 + F1 连击；无上次选区时回落普通截图 |
| FeatureGate ↔ StoreKit 沙盒 | 现阶段 `debugForcePro = true`（DEBUG/Release 全开，含 OCR/翻译/延时）；付费落地后再收口；StoreKit 购买/恢复待 Sandbox 联调 |
| 取色 HEX/RGB（C-09） | **已完成**：双格式色卡；C 复制 / Tab 切换 |
| 放大镜（C-08） | **已完成**：仅取色模式显示 |
| 选区方向键微调（C-07） | **已完成**：←↑↓→，Shift 步进 10 |
| 记号笔 / 橡皮（笔子菜单） | **已完成** |
| 菜单栏图标 | **已换**：MenuBarIcon 模板图；左键仅菜单 |
| 全局热键 | **已改**：F1 / F1×2 / ⌘T / F3 / ⌘H / ⌘⇧H |
| 快捷保存 ⌘S | **已完成**：Overlay 内写入快捷/默认目录；未配置则回落保存面板；⌘⇧S 另存为面板 |
| 保存目录与格式接线 | **已完成**：默认/快捷文件夹书签、png/jpeg、模板接保存面板 |
| 贴图上标注（P-11） | **已完成**：右键「标注」→ 底部工具条 → 完成写回 |
| 自动保存开关 | 尚未实现，仍然需要完善 |
| 光标下窗口 / 外部激活取消 | 尚未实现，仍然需要完善 |
| 自定义尺寸 | 暂时跳过不做，仍然需要完善 |
| 旋转镜像 / 缩略图 / 文件路径贴图 | 暂时跳过不做，仍然需要完善 |
| 序号标注 | 暂时跳过不做 |
| 开机启动（S-05） | **已完成**：设置 → 通用 Toggle；`SMAppService.mainApp` |
| 工具条单键热键 | 暂时跳过不做，仍然需要完善 |
| 本地化 / 性能打磨 | 暂时跳过不做，仍然需要完善 |
| 穿透 / 分组 / 历史 / 会话恢复 / 捕捉光标 | 明确不做（v1.0） |

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
