# 里程碑规划

单人全职估：**8–12 周** 至可提审。以接口骨架为起点，M0 创建 Xcode 工程。

进度摘要见 [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md)。

## M0 — 骨架（约 1 周）

- [x] 用 Xcode 创建 macOS App（Bundle `app.pinsnap.macos`，macOS 13，Universal）
- [x] 启用 App Sandbox；无多余 entitlement
- [x] MenuBarExtra / 状态栏图标
- [x] HotKeyCenter 注册 F1 / F1×2 / F3 / ⌘H / ⌘⇧H
- [x] 无权限时深链系统设置（**不做**自定义引导窗）
- [x] Settings 空壳（SwiftUI）
- [x] 把 `Sources/PinSnap/*` 接口文件纳入 target
- [x] 单元测试 target 可跑空测

**验收：** 安装运行 → 未授权可跳系统设置 → 热键有响应日志。

## M1 — 截图（约 2–3 周）

- [x] `ScreenGeometry` + 单测（混合 scale）
- [x] `CaptureService` 静止帧
- [x] Overlay：暗色遮罩、拖拽选区、Esc
- [x] 窗口级吸附（CGWindowList）
- [x] 出口：复制剪贴板、保存 PNG
- [x] **选区不跨屏**

**验收：** 需求 C-01–C-06；双屏不同缩放无错位。

## M2 — 标注 + 基础贴图（约 2–3 周）

- [x] Shape：rect/ellipse/line/arrow/freehand/text/mosaic/blur
- [x] Undo/Redo
- [x] PinPanel：置顶、拖动、滚轮缩放、透明度
- [x] 截图 → 贴图出口
- [x] 剪贴板图像 → 贴图（F3）
- [x] Free：第 4 张拦截 + 升级占位 UI

**验收：** 截→标→贴主路径；A-01–03；P-01/02/04。

## M3 — 贴图深度 + Pro 能力（约 2 周）

- [x] **砍掉（暂缓）**：穿透 + HUD（日后 Pro）
- [x] 关闭 / 销毁 / 隐藏全部（代码；生命周期表手工验收待勾）
- [x] **砍掉**：会话持久化与崩溃恢复
- [x] 剪贴板：文本渲染、色卡（代码；建议再验）
- [x] 延时、上次区域（状态栏菜单；延时固定 5s；上次区域另支持 F1 连击）
- [ ] FeatureGate 接真实 StoreKit（Sandbox）
- [ ] 其余 P1：放大镜/取色/像素微调/自动保存/旋转镜像/缩略图/贴图标注等

**验收：** Snipaste 语义用例表（docs 内手工清单）打勾。

## M4 — 上架打磨（约 1–2 周）

- [ ] Connect 商品与价格档对齐 PRD
- [ ] 简中 / English 本地化
- [ ] Info.plist 用途字符串定稿
- [ ] 性能：遮罩唤出、内存上限
- [ ] 隐私营养标签「不收集」
- [ ] TestFlight → 提审

**验收：** N-01–N-08；可提交审核。

## 之后

| 版本 | 内容 |
|---|---|
| v1.1 | OCR + 二维码 |
| v1.2 | AX 吸附、圆角阴影、文件名模板、色域 |
| v1.3+ | 长截图、录屏 |

## 并行前提

- Apple Developer 账号
- App Store Connect 创建 App + 内购三档
- 设计：菜单栏图标、升级页（可先用 SF Symbol）
