# PinSnap

> 菜单栏常驻的 macOS **截图 + 贴图**工具 · 对标 Snipaste 贴图深度 · 目标上架 Mac App Store

![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Status](https://img.shields.io/badge/M0%E2%80%93M2%20%E5%AE%8C%E6%88%90-M3%20%E8%BF%9B%E8%A1%8C%E4%B8%AD-blue)
[![GitHub Pages](https://img.shields.io/badge/GitHub%20Pages-still--lab.github.io%2Fpinsnap-222?logo=github&logoColor=white)](https://still-lab.github.io/pinsnap/)

一次截图，随取随贴。轻量常驻菜单栏，截图 → 标注 → 贴图一条龙，剪贴板里的图、文本、色卡也能一键贴成可置顶的小窗。

| 项 | 值 |
|---|---|
| Bundle ID | `app.pinsnap.macos` |
| 最低系统 | macOS 15.0 |
| 语言 | Swift · AppKit（截图/贴图）+ SwiftUI（设置） |
| 分发 | 仅 Mac App Store |
| 授权 | [MIT](LICENSE) |

## ✨ 功能特性

### 截图
- 区域截图、**窗口级吸附**（自动识别光标下窗口）
- **延时截图**（⌘T，固定 5s，菜单栏倒计时）
- **上次区域**（F1 连击 / 菜单，智能回落普通截图）
- 多屏混合缩放无错位（ScreenGeometry）

### 标注
- 矩形 / 椭圆 / 直线 / 箭头 / 手绘 / 文本 / 马赛克 / 模糊
- 记号笔 / 橡皮 / 撤销重做
- 选区方向键微调（←↑↓→，Shift 步进 10）、放大镜、取色（HEX/RGB 双格式）

### 贴图
- 置顶、拖动、**滚轮缩放**、空格滚轮调透明度
- 截图 → 贴图、剪贴板图片/文本/**色卡** → 贴图
- 贴图上右键标注，写回成图
- 关闭进栈（容量 5）、菜单「恢复最近关闭」

### 效率
- 全局热键（见下表）
- 快捷保存 ⌘S、⌘⇧S 另存；PNG/JPEG、存储目录书签、文件名模板
- OCR（Vision 文本 + 条码）
- 翻译（系统 Translation，中英互译；语言包已装可离线）

## ⌨️ 默认热键

| 按键 | 动作 |
|---|---|
| `F1` | 截图 |
| `F1 ×2` | 上次区域 |
| `⌘T` | 延时截图（5s） |
| `F3` | 剪贴板贴图 |
| `⌘H` | 隐藏全部贴图 |
| `⌘⇧H` | 显示全部贴图 |

## 💰 商业模型（已锁定）

| 版本 | 权益 |
|---|---|
| **Free** | 同时最多 3 张贴图，无水印 |
| **Pro** | ¥8/月 · ¥48/年 · ¥98 终身 |

## 🧭 文档索引

| 文档 | 说明 |
|---|---|
| [docs/PRD.md](docs/PRD.md) | 已锁定产品需求与商业决策 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 分层架构与运行时逻辑 |
| [docs/MODULES.md](docs/MODULES.md) | 模块职责、依赖、目录映射 |
| [docs/DATA_MODELS.md](docs/DATA_MODELS.md) | 核心数据模型与状态机 |
| [docs/MILESTONES.md](docs/MILESTONES.md) | M0–M4 与后续版本规划 |
| [docs/CODING_STANDARDS.md](docs/CODING_STANDARDS.md) | 编码约定 |
| [docs/FEATURE_MAP.md](docs/FEATURE_MAP.md) | 需求 ID → 模块 / 里程碑 |
| [docs/STORE_CHECKLIST.md](docs/STORE_CHECKLIST.md) | 上架与权限清单 |
| [docs/DELIVERY_PIPELINE.md](docs/DELIVERY_PIPELINE.md) | 全流程就绪度（需求→呈现） |
| [docs/UI_SPEC.md](docs/UI_SPEC.md) | UI 线框与信息架构 |
| [docs/ROADMAP_TASKS.md](docs/ROADMAP_TASKS.md) | 长程细粒度任务清单（370+） |
| [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) | 实施完成度与运行方式 |
| [docs/CONNECT_SETUP.md](docs/CONNECT_SETUP.md) | App Store Connect 前置清单 |

## 🏗️ 源码规划布局

```
Sources/PinSnap/
  App/           # 启动、菜单栏、热键、权限引导
  Capture/       # ScreenCaptureKit、多屏几何、窗口命中
  Overlay/       # 截图遮罩与选区 UI
  Annotate/      # 矢量标注与导出栅格化
  Pin/           # 贴图窗口、分组、会话、剪贴板桥
  Export/        # 存盘、文件名模板
  Purchase/      # StoreKit 2、FeatureGate
  Settings/      # SwiftUI 设置
  Vision/        # OCR（文本 + 条码）+ 系统翻译
  Support/       # 日志、Toast、通用工具
Tests/PinSnapTests/
docs/
```

可运行 macOS App（`xcodegen` / `xcodebuild`）。**M0–M2 完成，M3 进行中**；进度见 [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md)。

## 🚀 本地开发

```bash
# 生成并打开 Xcode 工程（需 Homebrew: xcodegen）
xcodegen generate
open PinSnap.xcodeproj

# 或命令行构建
xcodebuild -scheme PinSnap -configuration Debug -derivedDataPath build/DerivedData build

# 库单测
swift test
```

## 📅 版本规划

| 版本 | 状态 | 内容 |
|---|---|---|
| M0–M2 | ✅ 完成 | 骨架、截图、标注 + 基础贴图 |
| M3 | 🔄 进行中 | 贴图深度（生命周期/剪贴板桥）、Pro 能力 |
| M4 | ⏳ 未就绪 | 本地化 / Connect / TestFlight（需账号侧） |
| v1.1 | ✅ 代码落地 | OCR（Vision 文本 + 条码）、系统翻译 |
| v1.2 | 🦴 骨架 | AccessibilitySnap、文件名模板扩展 |
| v1.3+ | 🔄 进行中 | 长截图拼接（ScrollStitcher）、录屏 |

## 📄 License

[MIT](LICENSE) © 2026 会会
