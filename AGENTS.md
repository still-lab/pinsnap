# Agent / 协作者说明

本仓库当前阶段是 **代码规划 + 接口骨架**。实现请严格按 `docs/` 执行。

## 必读顺序

1. `docs/PRD.md` — 范围与商业锁定  
2. `docs/ARCHITECTURE.md` — 状态机与分层  
3. `docs/MODULES.md` — 改代码落哪个目录  
4. `docs/MILESTONES.md` — 当前应做的里程碑  
5. `docs/CODING_STANDARDS.md` — 约定  

## 硬规则

- `import ScreenCaptureKit` 只能在 `Sources/PinSnap/Capture/`。
- Free 贴图上限 **3**，无水印；门控走 `FeatureGate`。
- v1.0 不做 OCR / 长截图 / 录屏 / AX 元素吸附。
- 用户可见文案走本地化；设置页保持短标签。

## 下一步（人）

在 Xcode 创建 macOS App（M0），把本 Package 源码编入 App Target，或逐步迁移。
