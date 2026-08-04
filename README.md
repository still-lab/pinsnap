# PinSnap

菜单栏常驻的 macOS **截图 + 贴图**工具。对标 Snipaste 贴图深度，按 iShot 能力树分期扩展。目标上架 Mac App Store。

| 项 | 值 |
|---|---|
| Bundle ID | `app.pinsnap.macos` |
| 最低系统 | macOS 13.0 |
| 语言 | Swift · AppKit（截图/贴图）+ SwiftUI（设置） |
| 分发 | 仅 Mac App Store |
| 默认热键 | F1 截图 · F1×2 上次区域 · F3 贴图 · ⌘H 隐藏 · ⌘⇧H 显示 |

## 文档索引

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

## 源码规划布局

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
  Support/       # 日志、Toast、通用工具
Tests/PinSnapTests/
docs/
```

可运行 macOS App（`xcodegen` / `xcodebuild`）。**M0–M2 完成，M3 进行中**；进度见 [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md)。

## 商业（已锁定）

- Free：同时最多 3 张贴图，无水印
- Pro：¥8/月 · ¥48/年 · ¥98 终身

## 本地开发

```bash
# 生成并打开 Xcode 工程（需 Homebrew: xcodegen）
xcodegen generate
open PinSnap.xcodeproj

# 或命令行构建
xcodebuild -scheme PinSnap -configuration Debug -derivedDataPath build/DerivedData build

# 库单测
swift test
```

实施进度见 [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md)。

## License

专有软件，版权归项目所有者。未开源。
