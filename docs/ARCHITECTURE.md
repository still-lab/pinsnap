# 架构

## 原则

1. **沙盒优先**：只控自己的窗口；不碰私有 API。
2. **截图会话与贴图运行时解耦**：Committing 后可贴图，Pin 独立存活。
3. **禁止 UI 直连 ScreenCaptureKit**：一律经 `CaptureKit`（`Capture` 模块）。
4. **FeatureGate 横切**：Free/Pro 能力用枚举门控，不散落魔法布尔。
5. **本地优先**：v1.0 无网络依赖（内购收据校验除外）。

## 分层

```
┌─────────────────────────────────────────┐
│ AppShell（菜单栏 / 热键 / 权限 / 编排）   │
└────────────┬────────────────────────────┘
             │
     ┌───────┴───────┐
     ▼               ▼
 OverlayUI      ClipboardBridge
     │               │
     ▼               ▼
 CaptureKit ◄── 几何 / 截帧 / 窗口列表
     │
     ▼
 Annotator ←── Overlay 与 Pin 共用
     │
     ├──────────► Export
     └──────────► PinBoard（PinStore + NSPanel）
                     │
                     ▼
                 Persistence
 Purchase / FeatureGate ──────────────► 横切上述出口
```

## 截图会话状态机

```
Idle
  │ ⌃⇧A / 菜单
  ▼
Preparing ──权限失败──► Idle（深链系统设置，无引导窗）
  │ OK
  ▼
Capturing ──Esc──► Idle（丢弃）
  │ 确认选区
  ▼
Annotating（可跳过）──Esc──► 策略：回 Capturing 或 Idle（可配，默认回 Capturing）
  │ 出口
  ▼
Committing（copy / save / pin / saveAs）
  │
  ▼
Idle
```

## 贴图运行时

- 每张贴图一个 `NSPanel`（`.nonactivatingPanel`，floating）。
- `PinStore` 为唯一真相源；Panel 是视图投影。
- 定期 / 退出时原子写入 `Application Support/PinSnap/session/`。

## 坐标策略（v1.0）

- 选区存储：`screenID + logicalRect`（点）。
- 导出：`logicalRect × scale` → 像素裁剪。
- **选区不允许跨屏**（降低复杂度；后续可开虚拟桌面并集）。

## 线程

| 工作 | 队列 |
|---|---|
| SCK 截帧回调 | 转主线程更新 Overlay |
| CI 马赛克/模糊 | 后台，完成后主线程刷新 |
| 会话磁盘 IO | 后台串行队列 `pinsnap.session` |
| StoreKit | 系统回调转主线程更新 Gate |

## 安全与权限

| 权限 | 时机 |
|---|---|
| 屏幕录制 | 首次截图 Preparing |
| 辅助功能 | ≥ v1.2 元素吸附才申请 |
| 麦克风 | ≥ v1.3 录屏才申请 |
| 网络 | v1.0 仅 StoreKit；网页拖图为 P3 |
