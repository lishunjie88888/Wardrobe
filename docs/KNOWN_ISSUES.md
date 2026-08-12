# Known Issues（V1.0.0 Release Candidate）

只记录 V1.0.0 真实存在的限制；未实现的能力不作为已支持功能宣传。

## 功能限制

- **External ChatGPT 为人工交接**：应用只准备本地素材与 Prompt，需要用户手动在 ChatGPT 中发送并手动导入结果；无自动发送、无结果轮询。
- **无自动/付费 API Provider**：`VirtualTryOnProvider` 抽象与 Mock 保留，但未接入任何真实 AI API；应用不包含网络请求代码，无 API Key/Token。
- **无 cloud sync**：数据仅保存在本机，不提供多设备同步。
- **无 merge restore**：备份恢复仅支持「替换当前资料库」，不支持合并或选择性恢复。
- **无 scheduled/incremental backup**：备份为手动全量导出；无定时备份、无增量备份。

## 数据与安全

- **`.wardrobeBackup` V1 未加密**：备份包为明文（记录 + 图片 + 校验和），请自行妥善保管；不要通过不安全的渠道分发。
- **恢复为整体替换**：确认恢复前请先预览并备份当前资料库；失败时自动回滚到恢复前快照。
- **HEIF/HEIC 测试 fixture 条件跳过**：部分 macOS ImageIO 运行时不支持编码 HEIF/HEIC fixture，对应测试以 `XCTSkip` 跳过（依赖运行时能力，非 flaky）；导入 HEIC 实拍照片本身仍按系统解码能力处理。

## 发布状态

- **App Icon 待人工提供**：当前使用系统占位图标；正式 Wardrobe App Icon 资源尚未交付，Release Gate 不视为完成。
- **本地自用签名**：当前产物为 ad-hoc 签名（`Sign to Run Locally`），未 Developer ID 签名、未 notarize；请勿对外分发。需要公开分发时需另行完成 Developer ID + notarization。
- **Sandbox 迁移**：V1 启用 App Sandbox 后资料库位于容器路径（`~/Library/Containers/com.lishunjie.Wardrobe/...`）；0.1.0 开发期在容器外 `Application Support` 留下的数据不会被自动迁移，需通过备份/恢复手工迁移（V1 首发无正式生产数据）。
- **Debug 环境变量**：`WARDROBE_STORAGE_ROOT_OVERRIDE`、`WARDROBE_DEBUG_MOCK_GENERATION`、`WARDROBE_UI_TEST_*` 仅 Debug 构建生效，Release 构建不响应。
