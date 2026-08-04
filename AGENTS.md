# Agent / 协作者说明

本仓库当前阶段：**M0–M2 已完成，M3 进行中**（可运行 macOS App）。实现请严格按 `docs/` 执行；进度以 `docs/IMPLEMENTATION_STATUS.md` 为准。

## 必读顺序

1. `docs/PRD.md` — 范围与商业锁定  
2. `docs/ARCHITECTURE.md` — 状态机与分层  
3. `docs/MODULES.md` — 改代码落哪个目录  
4. `docs/MILESTONES.md` / `docs/IMPLEMENTATION_STATUS.md` — 里程碑与当前进度  
5. `docs/CODING_STANDARDS.md` — 约定  

## 硬规则

- `import ScreenCaptureKit` 只能在 `Sources/PinSnap/Capture/`。
- Free 贴图上限 **3**，无水印；门控走 `FeatureGate`（**现阶段 `isEnabled` 全开，全部免费；付费后期再梳**）。
- v1.0 不做长截图 / 录屏 / AX 元素吸附。
- v1.0 不做自定义权限引导窗、贴图分组、截图历史回放、会话恢复、捕捉光标；贴图穿透暂缓（日后 Pro）。
- 用户可见文案走本地化；设置页保持短标签。

## 下一步

- M3 收尾：StoreKit 真门控、`PIN_LIFECYCLE` 验收、其余 P1（放大镜/取色等）。
- M4：本地化与上架；账号侧见 `docs/CONNECT_SETUP.md`。
