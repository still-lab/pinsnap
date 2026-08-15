# PinSnap 长程任务规划（细粒度）

依据：`PRD.md` · `MILESTONES.md` · `UI_SPEC.md` · `ARCHITECTURE.md` · `FEATURE_MAP.md` · `STORE_CHECKLIST.md`  
用法：按顺序执行；`- [ ]` 可勾选。估时为单人全职参考（小时）。

**总周期参考：** 规划已完成 → v1.0 提审约 **8–12 周**；其后 v1.1–v1.3+ 另计。

---

## 图例

| 标记 | 含义 |
|---|---|
| P0/P1/P2/P3 | 需求优先级 |
| Hard | 阻塞后续 |
| Soft | 可并行 |
| Ext | 依赖外部（账号/设计/设备） |

---

# 阶段 A — 已完成（基线）

- [x] A-001 竞品能力拆解（Snipaste / iShot）
- [x] A-002 产品决策锁定（名、Bundle、价格、热键、Free≤3）
- [x] A-003 仓库初始化 `/Users/huihui/PinSnap` + git
- [x] A-004 文档：PRD / ARCHITECTURE / MODULES / DATA_MODELS
- [x] A-005 文档：MILESTONES / FEATURE_MAP / CODING_STANDARDS
- [x] A-006 文档：STORE_CHECKLIST / PIN_LIFECYCLE / DELIVERY_PIPELINE
- [x] A-007 文档：UI_SPEC 线框
- [x] A-008 SPM 模块骨架与协议
- [x] A-009 骨架单测可跑通（5）

---

# 阶段 B — 开工前置（Ext / Soft，约 4–12h）

## B1 Apple 与账号

- [ ] B-001 Ext 确认 Apple Developer Program 可用
- [ ] B-002 Ext App Store Connect 创建 App「PinSnap」
- [ ] B-003 Ext 登记 Bundle ID `app.pinsnap.macos`
- [ ] B-004 Ext 创建订阅组「PinSnap Pro」
- [ ] B-005 Ext 创建商品 `app.pinsnap.pro.monthly`（¥8）
- [ ] B-006 Ext 创建商品 `app.pinsnap.pro.yearly`（¥48，试用 7 天若允许）
- [ ] B-007 Ext 创建商品 `app.pinsnap.pro.lifetime`（¥98）
- [ ] B-008 Ext 配置沙盒测试账号
- [ ] B-009 Ext 准备隐私政策静态页 URL
- [ ] B-010 Ext 准备使用条款 URL
- [ ] B-011 Soft 团队若多人：约定证书/配置文件管理方式

## B2 设计资产（并行 Soft）

- [ ] B-020 Soft 菜单栏模板图标 16/18＠1x＠2x
- [ ] B-021 Soft App Icon 1024 与各尺寸
- [ ] B-022 Soft **砍掉**：权限引导示意图（无引导窗）
- [ ] B-023 Soft 升级页简单版式（可先用纯 SwiftUI）
- [ ] B-024 Soft 截图 Overlay 工具条图标套件（SF Symbol 可暂代）
- [ ] B-025 Soft App Store 五图构图草稿（按 UI_SPEC §9）

## B3 环境

- [ ] B-030 安装/确认 Xcode 版本支持 macOS 13 deployment
- [ ] B-031 准备外接显示器（混合缩放测试）Soft/Ext
- [ ] B-032 建立本地笔记：权限重置命令 `tccutil` 用法
- [ ] B-033 约定 Release 配置不启用 `debugForcePro`

---

# 阶段 C — M0 工程骨架（Hard，约 24–40h）

## C1 Xcode 工程

- [ ] C-001 创建 macOS App Target「PinSnap」
- [ ] C-002 Deployment macOS 13.0；Universal
- [ ] C-003 Bundle ID `app.pinsnap.macos`
- [ ] C-004 显示名 PinSnap；中文名「截图与贴图」本地化键
- [ ] C-005 启用 App Sandbox
- [ ] C-006 关闭不必要 Capabilities
- [ ] C-007 LSUIElement / 菜单栏 App 形态（无 Dock 或可选）
- [ ] C-008 将 `Sources/PinSnap/**` 纳入 App Target（或 SPM 依赖）
- [ ] C-009 建 Unit Test Target，链上现有测试
- [ ] C-010 `.gitignore` 已覆盖 xcuserdata（核对）
- [ ] C-011 配置 Debug / Release Scheme
- [ ] C-012 Soft 可选：SwiftLint 基础规则

## C2 应用入口与菜单栏

- [ ] C-020 `@main` App 入口接 `AppBootstrap.start()`
- [ ] C-021 NSStatusItem 菜单栏图标（LSUIElement，无 Dock 主窗）
- [ ] C-022 **左键单击图标 = 立即截图**（UI_SPEC 策略 A）
- [ ] C-023 **右键（或 ⌃+点）= 短动作菜单**
- [ ] C-024 菜单项：贴图 / 显隐贴图（截图可由左键承担，菜单可保留可省略）
- [ ] C-025 菜单沉底：设置… / 升级 Pro… / 退出
- [ ] C-026 菜单禁止堆次要功能（历史/OCR/录屏等）
- [ ] C-027 未授权时深链系统设置（无引导窗）
- [ ] C-028 Soft 后期：隐藏菜单栏图标 Toggle
- [ ] C-029 确认「没有主窗口」：激活 App 不出现空文档窗

## C3 热键

- [ ] C-030 实现 `HotKeyCenter.register`
- [ ] C-031 默认 ⌃⇧A / ⌃⇧V / ⌃⇧H
- [ ] C-032 热键触发打 Logger（截图/贴图/显隐）
- [ ] C-033 热键冲突检测 API
- [ ] C-034 冲突时设置页可提示（先 Toast/日志）
- [ ] C-035 App 退出 `unregister`
- [ ] C-036 单测或手工：改键后旧键失效

## C4 屏幕权限（无引导窗）

- [x] C-040 检测屏幕录制权限 API 封装
- [x] C-041 **砍掉**：无自定义引导窗（UI_SPEC §2）
- [x] C-042 未授权 → 深链系统设置（本进程最多一次）
- [x] C-043 **砍掉**：「稍后」按钮（无窗）
- [ ] C-044 从设置返回后下次热键重试即可（无需监听）
- [ ] C-045 系统跳转即可；无需 App 内权限文案键

## C5 设置壳

- [ ] C-050 SwiftUI Settings scene
- [ ] C-051 分段：通用 / 快捷键 / 存储 / Pro / 关于
- [ ] C-052 通用页占位 Toggle 绑定 UserDefaults
- [ ] C-053 快捷键页展示当前绑定（只读先）
- [ ] C-054 存储页占位路径 Label
- [ ] C-055 Pro 页占位三价按钮（未接 Store）
- [ ] C-056 关于：版本号 + 隐私/条款链接
- [ ] C-057 设置可从菜单打开

## C6 M0 验收

- [ ] C-060 干净安装跑通
- [ ] C-061 引导→系统设置可跳转
- [ ] C-062 三热键有日志
- [ ] C-063 沙盒开启下无崩溃
- [ ] C-064 提交 git：`chore: M0 app shell`

---

# 阶段 D — M1 截图核心（Hard，约 40–60h）

## D1 几何

- [ ] D-001 `ScreenGeometry.screens()` 读 NSScreen
- [ ] D-002 正确处理 `frame` / `visibleFrame` / scale
- [ ] D-003 `screen(containing:)`
- [ ] D-004 `pixelRect(for:)` 单测：scale 1/2
- [ ] D-005 单测：屏原点非零（外接排列）
- [ ] D-006 单测：选区超出屏边界 clamp
- [ ] D-007 约定全局逻辑坐标文档注释与实现一致
- [ ] D-008 v1.0 禁止跨屏选区：边界吸附实现

## D2 CaptureService

- [ ] D-020 权限 denied → `CaptureError.permissionDenied`
- [ ] D-021 ScreenCaptureKit 枚举 display
- [ ] D-022 静止帧捕获每屏一张
- [ ] D-023 帧与 `ScreenDescriptor` 对齐
- [ ] D-024 失败错误信息可读
- [ ] D-025 主线程回调纪律（async）
- [ ] D-026 性能：唤出前截帧耗时打点 Logger
- [ ] D-027 Soft 调研 `SCScreenshotManager` vs stream 单帧

## D3 WindowTracker

- [ ] D-030 `CGWindowListCopyWindowInfo`
- [ ] D-031 过滤 desktop / 不可见 / 自身面板
- [ ] D-032 点命中排序（上层优先）
- [ ] D-033 `WindowHit` 填充 name/bounds
- [ ] D-034 多屏坐标转换正确
- [ ] D-035 手工：点标题栏/内容区

## D4 Overlay UI

- [ ] D-040 每屏或全虚拟桌面遮罩 Panel
- [ ] D-041 暗色遮罩 + 选区透出
- [ ] D-042 拖拽创建选区
- [ ] D-043 拖拽调整选区边/角
- [ ] D-044 Esc 取消 → Idle
- [ ] D-045 窗口悬停高亮
- [ ] D-046 单击窗口吸附选区
- [ ] D-047 选区尺寸徽章（px）
- [ ] D-048 光标样式十字
- [ ] D-049 多屏：仅活跃屏可交互或全部同步策略选定并实现
- [ ] D-050 工具条容器出现时机：选区确定后
- [ ] D-051 工具条按钮：复制 / 保存 / 贴图 / 关闭（标注 M2）
- [ ] D-052 工具条 VisualEffect 背景
- [ ] D-053 Enter / ⌘C 复制出口
- [ ] D-054 ⌘S 保存面板
- [ ] D-055 贴图按钮先占位或 M2 接通

## D5 Export 基础

- [ ] D-060 按 selection 裁剪 CGImage
- [ ] D-061 复制到 NSPasteboard（PNG）
- [ ] D-062 保存 PNG 到用户选的 URL
- [ ] D-063 JPEG 可选（设置）
- [ ] D-064 默认目录 UserDefaults
- [ ] D-065 security-scoped bookmark 读写
- [ ] D-066 Toast：已复制 / 已保存
- [x] D-067 「成功截图」写入内存上次区域（供 C-10）

## D6 SessionCoordinator M1

- [ ] D-070 Idle→Preparing→Capturing→Committing→Idle
- [ ] D-071 权限失败走引导
- [ ] D-072 取消不进历史
- [ ] D-073 复制/保存算成功
- [ ] D-074 防止重入（截图中再按热键）

## D7 M1 验收

- [ ] D-080 需求 C-01–C-06 打勾
- [ ] D-081 内置 Retina 单测/手工
- [ ] D-082 外接 1x/2x 混合
- [ ] D-083 未授权路径
- [ ] D-084 提交：`feat: region and window capture`

---

# 阶段 E — M2 标注 + 基础贴图（Hard，约 40–60h）

## E1 标注模型与绘制

- [ ] E-001 Shape 补颜色 Codable
- [ ] E-002 矩形拖拽绘制
- [ ] E-003 椭圆
- [ ] E-004 直线
- [ ] E-005 箭头（三角箭头）
- [ ] E-006 自由画笔
- [ ] E-007 文字框（点击输入）
- [ ] E-008 马赛克（CIPixellate）
- [ ] E-009 模糊（CIGaussianBlur）
- [ ] E-010 线宽默认与滚轮调（基础）
- [ ] E-011 撤销/重做接工具条
- [ ] E-012 `exportFlattened` 真合成
- [ ] E-013 单测：多 shape flatten 非空
- [ ] E-014 工具条接入标注工具图标
- [ ] E-015 标注中右键结束当前笔画（若需要）

## E2 Pin 窗口基础

- [ ] E-020 NSPanel 创建与释放
- [ ] E-021 图像层显示
- [ ] E-022 拖动移动
- [ ] E-023 滚轮缩放（锚点光标下）
- [ ] E-024 透明度调节（空格+滚轮或菜单）
- [ ] E-025 floating + canJoinAllSpaces 默认策略
- [ ] E-026 关闭按钮/双击关闭策略选定（对齐关闭语义）
- [ ] E-027 Pin 图像落盘 session 目录
- [ ] E-028 `PinStore.create` 真实写文件
- [ ] E-029 截图工具条「贴图」→ create → 关遮罩
- [ ] E-030 ⌃⇧V 剪贴板图像 → create
- [ ] E-031 ClipboardBridge 读 TIFF/PNG
- [ ] E-032 失败 Toast「无法贴图」

## E3 Free 限额

- [ ] E-040 第 4 张抛错/拦截
- [ ] E-041 弹窗 UI_SPEC §5.1
- [ ] E-042 「升级 Pro」打开升级页
- [ ] E-043 「取消」
- [ ] E-044 单测：Free 下 create×4 失败
- [ ] E-045 debugForcePro 下可超过 3

## E4 升级页占位

- [ ] E-050 三价按钮 UI
- [ ] E-051 能力短列表
- [ ] E-052 恢复购买按钮（空实现）
- [ ] E-053 与 FeatureGate 假连通（手动开关测 UI）

## E5 M2 验收

- [ ] E-060 主路径截→标→复制
- [ ] E-061 截→贴
- [ ] E-062 剪贴板图→贴
- [ ] E-063 Free 3 张上限
- [ ] E-064 提交：`feat: annotate and basic pin`

---

# 阶段 F — M3 贴图深度 + Pro 能力（Hard，约 40–55h）

## F1 贴图生命周期

- [x] F-001 关闭 → closedStack
- [x] F-002 恢复栈容量配置（默认 1 或 5，写死并文档化）
- [x] F-003 贴图热键恢复关闭项逻辑
- [x] F-004 销毁删文件+模型
- [x] F-005 隐藏全部 / 显示全部
- [ ] F-006 隐藏不影响 closedStack 单测
- [x] F-007 右键菜单：关闭/销毁/复制/保存（穿透暂缓；贴图上标注待做）
- [ ] F-008 按 PIN_LIFECYCLE 表 1–9 手工打勾

## F2 穿透（暂缓 · 日后 Pro）

- [x] F-020 **砍掉（暂缓）**：`ignoresMouseEvents` 入口
- [x] F-021 **砍掉（暂缓）**：穿透 HUD Toast
- [x] F-022 **砍掉（暂缓）**：菜单「取消全部穿透」
- [x] F-023 **砍掉（暂缓）**：Free 点穿透 → 升级
- [x] F-024 FeatureGate.pinClickThrough（枚举保留，UI 暂不接）
- [x] F-025 **砍掉**：PinGroup CRUD
- [x] F-026 **砍掉**：切换活动组
- [x] F-027 **砍掉**：组管理 UI
- [x] F-028 **砍掉**：FeatureGate.pinGroups

## F3 会话持久化（不做）

- [x] F-030 **砍掉**：meta.json + png 布局（会话恢复）
- [x] F-031 **砍掉**：AtomicFile 会话写入
- [x] F-032 **砍掉**：启动 restoreSession
- [x] F-033 **砍掉**：定时 autosave
- [x] F-034 **砍掉**：退出前 persist
- [x] F-035 **砍掉**：损坏 meta 恢复策略
- [x] F-036 **砍掉**：Free 是否持久化

## F4 剪贴板增强

- [x] F-040 纯文本 → TextKit 渲染图
- [x] F-041 HTML 简化或当纯文本（现按纯文本 string）
- [x] F-042 颜色 `#RGB` / `#RRGGBB` → 色卡
- [x] F-043 文件 URL 图片加载
- [ ] F-044 单测 Clipboard 矩阵（mock pasteboard 若可）

## F5 贴图进阶交互

- [ ] F-050 旋转 / 镜像快捷键或菜单
- [ ] F-051 缩略图模式
- [ ] F-052 贴图上标注（空格/右键）
- [ ] F-053 标注写回该 Pin 文件

## F6 截图 P1 能力

- [ ] F-060 WASD 微移光标/选区
- [x] F-061 方向键改选区（←↑↓→，Shift×10）
- [x] F-062 放大镜
- [x] F-063 取色复制 HEX/RGB
- [x] F-064 设置切换色值格式
- [x] F-065 上次区域截图（状态栏菜单；热键暂缓统一规划）
- [x] F-066 延时截图（状态栏菜单，固定 5s，菜单栏倒计时；热键暂缓）
- [x] F-067 **砍掉**：捕捉光标 Toggle + 实现
- [x] F-068 **砍掉**：历史回放 UI
- [ ] F-069 快捷保存目录 ⌘⇧S
- [ ] F-070 自动保存选项
- [ ] F-071 光标下窗口一键截
- [ ] F-072 外部激活取消截图 Toggle（默认关）

## F7 设置补全

- [ ] F-080 快捷键录制控件真改绑定
- [x] F-081 开机启动 SMAppService
- [ ] F-082 文件名模板（Pro 可编辑）
- [ ] F-083 存储格式 png/jpeg
- [ ] F-084 所有文案进 xcstrings 中英

## F8 StoreKit 初接

- [ ] F-090 Product.products 拉三档
- [ ] F-091 purchase 流
- [ ] F-092 currentEntitlements → applyEntitlement
- [ ] F-093 Transaction.updates 监听
- [ ] F-094 restore
- [ ] F-095 沙盒买月订/年订/终身各一遍
- [ ] F-096 过期后门控回 Free（贴图保留）
- [ ] F-097 Release 禁用 debugForcePro 编译条件

## F9 M3 验收

- [ ] F-100 PIN_LIFECYCLE 全过
- [ ] F-101 Pro/Free 切换行为正确
- [ ] F-102 提交：`feat: pin depth and storekit`

---

# 阶段 G — M4 打磨与提审（Hard，约 24–40h）

## G1 质量

- [ ] G-001 遮罩唤出耗时优化（目标 P95&lt;100ms 暖启动）
- [ ] G-002 内存：历史/贴图上限与降采样
- [ ] G-003 大图马赛克后台化防卡 UI
- [ ] G-004 崩溃点复查（强制解包、主线程 IO）
- [ ] G-005 日志级别 Release 收敛
- [ ] G-006 Soft Instruments Time Profiler 截一轮

## G2 兼容手工矩阵

- [ ] G-010 macOS 13 虚拟机或机器
- [ ] G-011 macOS 14
- [ ] G-012 macOS 15
- [ ] G-013 Stage Manager 开/关
- [ ] G-014 全屏其他 App 时截图
- [ ] G-015 刘海屏菜单栏
- [ ] G-016 锁屏不误截
- [ ] G-017 Intel 机（若有）或 Universal 校验

## G3 本地化与文案

- [ ] G-020 xcstrings 全量中英
- [ ] G-021 设置/菜单/Toast/升级页过一遍截断
- [ ] G-022 Info.plist 屏幕用途中英
- [ ] G-023 商店描述草稿中英（短句）

## G4 商店呈现

- [ ] G-030 拍摄/制作 5 张 AS 截图
- [ ] G-031 Soft 可选预览视频
- [ ] G-032 副标题、关键词
- [ ] G-033 隐私营养标签：不收集
- [ ] G-034 年龄 4+
- [ ] G-035 审核备注：说明屏幕权限用途、无上传
- [ ] G-036 内购截图说明（若需要）

## G5 提审

- [ ] G-040 Archive 签名
- [ ] G-041 上传 Transporter / Organizer
- [ ] G-042 TestFlight 内部测 ≥2 人天
- [ ] G-043 修 TestFlight 阻断 bug
- [ ] G-044 提交审核
- [ ] G-045 拒审清单预案（权限文案、内购、沙盒行为）
- [ ] G-046 过审后放阶段发布或立即发布决策
- [ ] G-047 打 tag `v1.0.0`
- [ ] G-048 提交：`chore: release 1.0.0`

---

# 阶段 H — v1.0 发布后运营（Soft，持续）

- [ ] H-001 收集 AS 评论关键词
- [ ] H-002 崩溃无第三方时：靠用户反馈建 issue
- [ ] H-003 热键冲突常见 App 列表文档化
- [ ] H-004 价格/转化粗看（Connect 分析）
- [ ] H-005 下个版本范围从评论投票

---

# 阶段 I — v1.1 OCR（约 2–3 周）

- [ ] I-001 Vision VNRecognizeTextRequest 封装
- [ ] I-002 截图工具条 OCR 按钮（Pro）
- [ ] I-003 结果复制剪贴板
- [ ] I-004 取消换行选项
- [ ] I-005 二维码/条码优先 VNDetectBarcodes
- [ ] I-006 连续 OCR 模式（可选）
- [ ] I-007 权限/隐私文案确认仍本地
- [ ] I-008 中英识别效果抽样集
- [ ] I-009 FeatureGate 新 feature 或复用 advanced
- [ ] I-010 AS 更新说明
- [ ] I-011 提审 v1.1

---

# 阶段 J — v1.2 吸附与美化（约 2–4 周）

- [ ] J-001 Accessibility 权限引导文案
- [ ] J-002 AXUIElement 元素矩形
- [ ] J-003 父子元素滚轮切换
- [ ] J-004 设置中开关元素吸附
- [ ] J-005 圆角导出
- [ ] J-006 阴影导出
- [ ] J-007 色域 sRGB / Display P3
- [ ] J-008 文件名模板变量完整实现
- [ ] J-009 双击修饰键用指定 App 打开（书签）
- [ ] J-010 HD/SD 档（若仍需要）
- [ ] J-011 回归 M1 截图全路径
- [ ] J-012 提审 v1.2

---

# 阶段 K — v1.3+ 重型（约 4–8 周+）

## K1 长截图

- [x] K-001 滚动捕获模式 UI
- [x] K-002 手动滚 + 帧采集
- [x] K-003 条带特征拼接算法
- [x] K-004 水平漂移容错
- [x] K-005 内存分块 / 尺寸上限
- [ ] K-006 失败提示与部分结果保存
- [ ] K-007 Soft 自动滚实验（可放弃）
- [x] K-008 成功率测试集（网页/聊天/文档）— 见 `docs/SCROLL_CAPTURE_QA.md`
## K2 录屏

- [ ] K-020 SCK 音视频流
- [ ] K-021 麦权限文案
- [ ] K-022 系统音策略调研与实现可行性
- [ ] K-023 光标/点击高亮
- [ ] K-024 AVAssetWriter MP4
- [ ] K-025 GIF 导出（短时限）
- [ ] K-026 录制中菜单栏状态
- [ ] K-027 长时 30min+ 稳定测试

## K3 其它 P3

- [ ] K-040 带壳模板
- [ ] K-041 多窗口拼贴
- [ ] K-042 白板模式
- [ ] K-043 热键忽略列表（前台 App）
- [ ] K-044 命令面板 / URL Scheme
- [ ] K-045 屏幕触发角（慎与系统冲突）
- [ ] K-046 翻译（系统 Translation）
- [ ] K-047 Solo / 多选贴图等 Snipaste Pro 项拣选

---

# 阶段 L — 质量体系（贯穿，Soft）

- [ ] L-001 CI：`swift test`（GitHub Actions Mac runner 若可用）
- [ ] L-002 每个 feat PR 关联 FEATURE_MAP ID
- [ ] L-003 发布前跑 PIN_LIFECYCLE 清单
- [ ] L-004 发布前跑 STORE_CHECKLIST
- [ ] L-005 几何单测不得删
- [ ] L-006 关键路径录像存档（内部）
- [ ] L-007 版本 Changelog 文件维护

---

# 阶段 M — 风险与应急任务

- [ ] M-001 SCK 黑屏：权限重置流程文档
- [ ] M-002 审核拒「权限不清」：改 plist 备选文案×3
- [ ] M-003 审核拒内购：沙盒录屏证明
- [ ] M-004 贴图被 Stage Manager 挡住：层级备选方案
- [ ] M-005 热键全局失效：排查输入法/安全软件清单
- [ ] M-006 会话文件损坏：用户「重置贴图会话」按钮
- [ ] M-007 StoreKit 连不上：错误态与重试
- [ ] M-008 名称商标冲突：备选名列表（若 AS 被拒）

---

# 建议排期视图（压缩）

| 周 | 焦点 |
|---|---|
| W0 | B 前置 + C M0 |
| W1–W3 | D M1 |
| W4–W6 | E M2 |
| W7–W8 | F M3 |
| W9–W10 | G M4 + 提审 |
| W11+ | 过审修返 / H 运营 |
| 其后 | I → J → K |

设计 B2 与 W0–W6 **全程并行**。

---

# 统计（约数）

| 阶段 | 条目约数 |
|---|---|
| A 已完成 | 9 |
| B 前置 | ~25 |
| C M0 | ~45 |
| D M1 | ~55 |
| E M2 | ~45 |
| F M3 | ~70 |
| G M4 | ~40 |
| H 运营 | ~5 |
| I–K 后续 | ~55 |
| L–M 质量/应急 | ~20 |
| **合计** | **~370+** |

v1.0 关键路径 ≈ **B 必要项 + C + D + E + F + G**（约 **250** 个执行点量级）。

---

# 下一步（立刻可做的 5 件）

1. B-001–B-003 账号与 Connect App  
2. C-001 创建 Xcode 工程  
3. B-020 菜单栏图标（或先 SF Symbol）  
4. C-030 热键真注册  
5. D-001 几何单测用人造 ScreenDescriptor 先写红/绿  

勾选时建议在本文件直接改 `- [x]`，或导入 issue 时保留编号（如 `D-042`）便于追溯。
