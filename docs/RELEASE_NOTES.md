# Release Notes

## V1.0.0（2026-08-12，Release Candidate）

首个可长期自用的 V1 发布候选。构建信息：`MARKETING_VERSION 1.0.0`、`CURRENT_PROJECT_VERSION 1`、Bundle ID `com.lishunjie.Wardrobe`、最低 macOS 15.0。

### 衣橱管理

- 衣物照片导入（JPEG/PNG/HEIC 按运行时能力）、方向修正、处理后图片与缩略图生成。
- 名称、分类、子分类、品牌、颜色、季节、风格、材质、标签、备注与收藏。
- 网格浏览、搜索、组合筛选、排序、归档与二次确认的永久删除（被历史引用时保留资源）。

### 人物档案

- 人物档案与多张全身参考照；默认人物与主参考照规则稳定；归档与删除保护历史快照。

### AI 试衣间（External ChatGPT Workflow）

- 语义化槽位（上装/下装/鞋履/配饰/其他）与拖放组合。
- 本地生成有序参考图、`prompt.txt`、`manifest.json` 并复制 Prompt；用户在 ChatGPT 人工发送后导入结果。
- 无自动/付费 API Provider；应用本身不发起任何网络请求。

### 穿搭与生成历史

- 保存/编辑/搜索/收藏/载入 Outfit；载入前逐槽位 preflight。
- Generation History：人物/衣物快照、Prompt、来源与结果持久化，支持重新生成与删除保护。

### 备份 / 恢复

- `.wardrobeBackup` v1 包：记录 + 资产 + 校验和；验证、预览、确认替换、重启后应用、失败回滚快照。
- 备份排除 cache/staging/external-generations/日志；V1 备份未加密。

### Migration 基础

- `WardrobeSchemaV1`（schema 1.0.0 / storage layout 1）冻结；`LibraryMigrationCoordinator` 与 preflight 建立未来升级基础；V1 数据库 fixture 不可变。

### 性能与可靠性

- 缩略图优先、缓存 LRU 驱逐（512 MB）、过期 staging 启动恢复、磁盘不足防护、孤儿文件只读报告与确认清理、中断恢复与补偿事务。

### 隐私模型

- App Sandbox + 用户所选文件读写；无网络权限、无 Keychain 凭据、无 Cookie/浏览器访问；日志不记录私人路径或 Prompt 原文；敏感键值脱敏。

### 签名与分发

- 本机构建：ad-hoc 签名（`Sign to Run Locally`），未 Developer ID 签名、未 notarize；仅限本机/个人自用分发。
- App Icon 使用系统占位图标，正式图标资源待人工提供（见 `KNOWN_ISSUES.md`）。
