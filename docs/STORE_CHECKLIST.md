# 上架与权限清单

## App Store Connect

- [ ] App 记录：PinSnap，Bundle `app.pinsnap.macos`
- [ ] 类别：效率
- [ ] 年龄分级：4+
- [ ] 隐私政策 URL（可先静态页）
- [ ] 截图（菜单栏 + 截图遮罩 + 贴图场景）中英各一套

## 内购

| Product ID | 类型 | 价格（CN） |
|---|---|---|
| `app.pinsnap.pro.monthly` | 订阅 | ¥8 |
| `app.pinsnap.pro.yearly` | 订阅 + 试用 7 天（若允许） | ¥48 |
| `app.pinsnap.pro.lifetime` | 非消耗型 | ¥98 |

- [ ] 订阅组「PinSnap Pro」
- [ ] 沙盒账号测购买 / 恢复 / 过期

## Entitlements（v1.0）

- App Sandbox：ON
- 出站网络：仅若 StoreKit 需要（通常系统处理）
- **不要**过早加 Accessibility / Microphone

## Info.plist 用途（草稿）

**屏幕录制：**  
用于在用户按下截图快捷键时捕获用户选定的屏幕区域，以便标注、复制、保存或贴图。默认不上传至任何服务器。

（录屏/麦克风文案留到 v1.3 再加。）

## 隐私营养标签

v1.0：**不收集数据**。

## 提审前自测

- [ ] 无权限时失败可理解且可跳转设置
- [ ] 订阅门控：第 4 张贴图
- [ ] 中英切换无截断错乱
- [ ] 双屏 Retina
- [ ] ~~冷启动恢复贴图会话~~（v1.0 不做）
