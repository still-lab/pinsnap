# App Store Connect 配置清单（阶段 B）

本地已准备商品 ID 与法务页。以下 **Ext** 项需在你的 Apple Developer / Connect 账号中完成。

## 商品 ID（与代码 `StoreProductID` 一致）

| Product ID | 类型 | 价格（CN） |
|---|---|---|
| `app.pinsnap.pro.monthly` | 自动续期订阅 | ¥8 |
| `app.pinsnap.pro.yearly` | 自动续期订阅（建议 7 天试用） | ¥48 |
| `app.pinsnap.pro.lifetime` | 非消耗型 | ¥98 |

订阅组建议名：`PinSnap Pro`

## Bundle

- Bundle ID：`app.pinsnap.macos`
- 显示名：PinSnap

## 法务页（先托管再填 Connect）

仓库内静态页：

- [`docs/legal/privacy.html`](legal/privacy.html)
- [`docs/legal/terms.html`](legal/terms.html)

托管后将 URL 填入 App Store Connect 与 App「关于」。

## 操作勾选（人工）

- [ ] Developer Program 有效
- [ ] Connect 创建 App
- [ ] 登记 Bundle ID
- [ ] 创建订阅组与三档商品
- [ ] 沙盒测试账号
- [ ] 隐私/条款 URL 上线并粘贴

图标资产见 `Resources/icons/`（可替换为正式设计）。
