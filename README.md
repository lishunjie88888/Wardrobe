# Wardrobe

原生 macOS 电子衣橱应用（SwiftUI + SwiftData）。本地优先：衣物、人物、穿搭、生成历史与备份全部保存在本机，不上传图片、不调用付费 AI API。

## 系统要求

- macOS 15.0 或更高
- Apple Silicon 或 Intel（Release Archive 为 universal 构建）
- 首次发布为本地自用构建（ad-hoc 签名），不包含 Developer ID / notarization

## 安装 / 运行

- 开发运行：用 Xcode 打开 `Wardrobe.xcodeproj`，选择 `Wardrobe` scheme 后 Run。
- 发布构建：

```bash
xcodebuild build -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Release
xcodebuild archive -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Release \
  -archivePath /tmp/Wardrobe.xcarchive
```

- Release 应用位于 `Build/Products/Release/Wardrobe.app` 或 `Wardrobe.xcarchive/Products/Applications/Wardrobe.app`，直接复制到「应用程序」即可运行。
- DMG 分发：`Wardrobe-1.0.0.dmg`（免费测试分发，ad-hoc 签名，未 Developer ID 签名、未 notarize）。打开 DMG → 把 `Wardrobe.app` 拖入 `Applications` → 首次启动若被 Gatekeeper 拦截，请到「系统设置 → 隐私与安全性」点击「仍要打开」。**不要使用 `sudo spctl --master-disable` 关闭 Gatekeeper**。

## 资料库位置

应用启用 App Sandbox，资料库位于容器内：

```
~/Library/Containers/com.lishunjie.Wardrobe/Data/Library/Application Support/com.lishunjie.Wardrobe/Wardrobe/
```

- `database/`：SwiftData 元数据（`WardrobeV1.store`）
- `garments/`、`persons/`、`generations/`、`outfits/`：受控图片资源
- `staging/`：临时操作工作区（启动时自动恢复过期操作）
- `cache/previews`、`cache/provider`：可随时清理的缓存（512 MB 上限，LRU 驱逐）
- `backups/`：备份包
- `external-generations/`：External ChatGPT 流程的本地导出素材

Debug 构建可用环境变量 `WARDROBE_STORAGE_ROOT_OVERRIDE` 覆盖资料库根目录（仅 Debug 生效）。

## 基本流程

1. **衣物**：我的衣橱 → 导入照片 → 填写分类/品牌/颜色/季节/风格/标签 → 自适应网格浏览、搜索、筛选、排序；支持归档与二次确认的永久删除。
2. **人物**：创建人物档案 → 导入多张全身参考照 → 设置默认人物与主参考照。
3. **AI 试衣间**：选择人物 → 将衣物拖入语义化槽位（上装/下装/鞋履/配饰/其他）→ 生成搭配。
4. **穿搭**：保存当前搭配为 Outfit，支持搜索、收藏与载入。
5. **生成历史**：查看每次生成的人物/衣物快照、Prompt、来源与结果，可重新生成。

## External ChatGPT Workflow

Wardrobe 本身**不集成付费 AI API、不发送任何请求**。流程为人工交接：

1. 在试衣间点击「生成搭配」，应用在 `external-generations/ChatGPT-TryOn-<id>/` 准备有序参考图、`prompt.txt` 与 `manifest.json`，并把 Prompt 复制到剪贴板、在 Finder 中显示素材文件夹。
2. 用户打开 ChatGPT，人工确认后上传素材并发送。
3. 生成完成后，用户把结果图片放入素材文件夹（或任意位置），在应用中导入该图片。
4. 导入后保存输入快照、Prompt、来源（`external-chatgpt-manual`）与生成结果。

## 备份与恢复

- 设置 → 备份与恢复 →「创建备份」：导出 `.wardrobeBackup` 包（记录 + 资产 + 校验和）。
- 备份**未加密**，请妥善保管。
- 恢复：选择备份包 → 校验与预览（记录数、资产数、字节、来源库）→ 确认替换 → 重启应用后在打开资料库前应用；恢复前自动建立可回滚快照，失败自动还原。
- V1 仅支持「替换当前资料库」，不支持合并恢复。

## 存储维护

- 「清理缓存」随时可执行，不影响衣物/人物/生成历史。
- 「扫描孤儿文件」只读报告缺失引用与无引用文件；清理需单独确认，且只删除宽限期（7 天）后仍未被引用的文件，逐个删除、不删目录。

## 数据隐私

- 数据仅保存在本机；应用不包含网络请求代码。
- 无 API Key、无 Token；不读取浏览器 Cookie，不请求 Accessibility/Apple Events 等权限。
- 文件导入/备份/恢复通过系统打开/保存面板选择路径，仅持有用户所选文件的读写权限。
- Prompt、路径与错误信息中不记录私人照片路径；生成历史中的敏感键值在展示前脱敏。

## 故障恢复

- 启动时自动执行：待恢复事务应用、过期 staging 恢复、storage migration preflight；无法安全打开资料库时阻止启动并提示。
- 磁盘不足、导入失败、生成中断、恢复回滚失败均有明确错误提示与安全处理。
- 若资料库损坏：优先用最近备份在隔离目录验证后恢复；V1 备份格式为 `wardrobeBackup` v1。

## 开发 / 测试方式

- 架构与数据模型：见 `docs/ARCHITECTURE.md`、`docs/DATA_MODEL.md`、`docs/STORAGE_SPEC.md`、`docs/AI_ARCHITECTURE.md`、`docs/PRODUCT_SPEC.md`、`docs/UI_SPEC.md`。
- 单元测试全部使用 in-memory SwiftData 或 `/tmp` 隔离根，不触碰真实资料库：

```bash
xcodebuild test -project Wardrobe.xcodeproj -scheme Wardrobe -destination 'platform=macOS'
```

- UI 测试 target（`WardrobeUITests`）编译验证；运行时 UI 闭环采用人工验收（见 `CODEX_EXECUTION_CHECKLIST.md`）。
- Mock Provider 与 `WARDROBE_DEBUG_MOCK_GENERATION`（Debug + 环境变量）仅用于开发/测试，Release 构建不暴露。
- 已知限制与未完成项：见 `docs/KNOWN_ISSUES.md`；发布记录见 `docs/RELEASE_NOTES.md`。
