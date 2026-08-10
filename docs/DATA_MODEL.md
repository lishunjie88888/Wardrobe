# V1 数据模型

## 1. 建模原则

- SwiftData 只保存元数据、关系、状态与受控资源 ID，不保存完整图片二进制。
- 每个持久模型使用应用生成的 UUID 作为稳定业务 ID；UUID 创建后不可变，不使用 SwiftData 内部标识作为跨层或备份标识。
- 所有持久模型包含 `createdAt` 和 `updatedAt`。时间统一存储为绝对 `Date`，显示时才应用时区。
- 可演进枚举在持久层存储稳定的字符串 code；Domain/Repository 将 code 映射到 Swift 枚举。遇到未知 code 时保留原值并在 UI 显示“其他/未知”，避免升级或降级时丢数据。
- V1 采用软归档保护引用历史；永久删除必须经过专用 Service。
- 资源字段使用 `StorageResourceID` 的字符串表示，格式和安全规则见 [STORAGE_SPEC.md](STORAGE_SPEC.md)。

## 2. 公共约定

| 约定 | 说明 |
| --- | --- |
| `id: UUID` | 非可选、应用生成、唯一、不可变 |
| `createdAt: Date` | 非可选，默认当前时间，创建后不变 |
| `updatedAt: Date` | 非可选，默认当前时间，每次业务修改时更新 |
| `archivedAt: Date?` | `nil` 表示活跃；非空表示软归档 |
| `...Code: String` | 稳定持久化 code，不直接依赖枚举 case 名称 |
| `...ResourceID: String` | Storage Service 签发和解析的相对资源 ID |

需要唯一约束的 UUID 应使用 SwiftData 唯一属性。唯一性冲突在 Repository 层转换为领域错误。

## 3. 模型

### 3.1 ClothingItem

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 稳定衣物 ID |
| `name` | `String` | 否 | `""` | 展示名称；保存前校验非空 |
| `notes` | `String` | 是 | `nil` | 用户备注 |
| `categoryCode` | `String` | 否 | `other` | `ClothingCategory` code |
| `subcategoryCode` | `String` | 是 | `nil` | `ClothingSubcategory` code；允许未来扩展 |
| `brand` | `String` | 是 | `nil` | 规范化空白后的品牌 |
| `colorCodes` | `[String]` | 否 | `[]` | 颜色 code 或用户定义颜色 ID |
| `seasonCodes` | `[String]` | 否 | `[]` | `Season` code；空数组表示未指定 |
| `styleCodes` | `[String]` | 否 | `[]` | `StyleTag` code |
| `materials` | `[String]` | 否 | `[]` | 规范化材质名称 |
| `tags` | `[String]` | 否 | `[]` | 用户自定义普通标签，去重保存 |
| `isFavorite` | `Bool` | 否 | `false` | 是否收藏 |
| `originalResourceID` | `String` | 否 | 无 | 原始衣物图资源 ID |
| `processedResourceID` | `String` | 是 | `nil` | 处理后 PNG 资源 ID |
| `thumbnailResourceID` | `String` | 是 | `nil` | 缩略图资源 ID |
| `archivedAt` | `Date` | 是 | `nil` | 软归档时间 |
| `createdAt` | `Date` | 否 | 当前时间 | 创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 修改时间 |

关系：一个 `ClothingItem` 可被多个 `OutfitItem` 和 `GenerationGarmentInput` 引用。反向关系使用 `.nullify`，永久删除衣物不会删除穿搭或生成历史；引用子项保留 `clothingItemID` 和快照字段。

### 3.2 PersonProfile

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 稳定人物 ID |
| `name` | `String` | 否 | `"我"` | 人物名称 |
| `notes` | `String` | 是 | `nil` | 备注 |
| `isDefault` | `Bool` | 否 | `false` | 默认人物标记 |
| `archivedAt` | `Date` | 是 | `nil` | 软归档时间 |
| `createdAt` | `Date` | 否 | 当前时间 | 创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 修改时间 |

关系：`images: [PersonImage]`，PersonProfile 删除到 PersonImage 为 `.cascade`，但永久删除前必须检查生成历史并由 Service 决定是否保留快照资源。应用服务保证活跃档案至多一个 `isDefault == true`；该约束不能仅依赖 UI。

### 3.3 PersonImage

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 稳定人物图片 ID |
| `profile` | `PersonProfile` | 否 | 无 | 所属人物，反向删除 `.cascade` |
| `isPrimary` | `Bool` | 否 | `false` | 此人物的默认参考照 |
| `originalResourceID` | `String` | 否 | 无 | 原始全身照资源 ID |
| `processedResourceID` | `String` | 是 | `nil` | 标准化处理图资源 ID |
| `thumbnailResourceID` | `String` | 是 | `nil` | 缩略图资源 ID |
| `pixelWidth` | `Int` | 是 | `nil` | 已知时保存，便于校验 |
| `pixelHeight` | `Int` | 是 | `nil` | 已知时保存，便于校验 |
| `createdAt` | `Date` | 否 | 当前时间 | 创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 修改时间 |

关系：一个 `PersonImage` 可被多个 `GenerationPersonInput` 以可空关系引用。应用服务保证每个 PersonProfile 至多一张 `isPrimary == true`；删除主图时自动选择新主图或将其置空，并明确通知 UI。

### 3.4 Outfit

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 稳定穿搭 ID |
| `name` | `String` | 否 | `"未命名穿搭"` | 展示名称 |
| `notes` | `String` | 是 | `nil` | 备注 |
| `isFavorite` | `Bool` | 否 | `false` | 是否收藏 |
| `coverResourceID` | `String` | 是 | `nil` | 可选封面；可来自生成结果的受控副本或专用封面 |
| `archivedAt` | `Date` | 是 | `nil` | 软归档时间 |
| `createdAt` | `Date` | 否 | 当前时间 | 创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 修改时间 |

关系：`items: [OutfitItem]`，Outfit 到 OutfitItem 为 `.cascade`。至少包含一个有效 OutfitItem 才能保存；重复槽位规则由 `TryOnSlot` 决定。

### 3.5 OutfitItem

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 稳定子项 ID |
| `outfit` | `Outfit` | 否 | 无 | 所属穿搭 |
| `clothingItem` | `ClothingItem` | 是 | `nil` | 当前可用衣物关系，删除规则 `.nullify` |
| `clothingItemID` | `UUID` | 否 | 无 | 创建时复制，关系失效后仍可追溯 |
| `clothingNameSnapshot` | `String` | 否 | `""` | 创建或显式刷新时的名称快照 |
| `thumbnailResourceIDSnapshot` | `String` | 是 | `nil` | 可选缩略图资源快照引用 |
| `slotCode` | `String` | 否 | 无 | `TryOnSlot` code |
| `sortOrder` | `Int` | 否 | `0` | 同一槽位内顺序，主要用于 Accessories |
| `createdAt` | `Date` | 否 | 当前时间 | 创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 修改时间 |

V1 中 `upperBody`、`outerwear`、`lowerBody`、`footwear` 各最多一个衣物；`accessories` 可有多个，并按 `sortOrder` 排序。约束由 Outfit Service 和 Try-On State 共同校验。没有可靠槽位映射的衣物仍可正常管理，但 V1 不允许将其静默映射到错误槽位。

### 3.6 GenerationRecord

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 稳定生成 ID，也作为资源目录 owner ID |
| `sourceGenerationID` | `UUID` | 是 | `nil` | 重新生成时指向来源记录，不建立强级联关系 |
| `providerID` | `String` | 否 | 无 | 稳定 Provider 标识，如 `mock`；不存展示名 |
| `providerModelID` | `String` | 是 | `nil` | 当次实际模型/版本标识 |
| `statusCode` | `String` | 否 | `queued` | `GenerationStatus` code |
| `prompt` | `String` | 否 | `""` | 当次最终 Provider 中立 Prompt 快照 |
| `optionsJSON` | `String` | 否 | `"{}"` | 有版本号的 Provider 中立参数 JSON |
| `providerRequestID` | `String` | 是 | `nil` | 供应商请求 ID，用于诊断；不含凭据 |
| `resultResourceID` | `String` | 是 | `nil` | 成功生成图资源 ID |
| `resultThumbnailResourceID` | `String` | 是 | `nil` | 成功结果缩略图 |
| `errorCode` | `String` | 是 | `nil` | 规范化错误 code |
| `errorMessage` | `String` | 是 | `nil` | 可展示的脱敏错误摘要 |
| `attemptCount` | `Int` | 否 | `0` | 实际 Provider 尝试次数 |
| `startedAt` | `Date` | 是 | `nil` | 开始调用时间 |
| `completedAt` | `Date` | 是 | `nil` | 成功、失败或取消时间 |
| `createdAt` | `Date` | 否 | 当前时间 | 请求记录创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 状态更新时间 |

关系：`personInputs: [GenerationPersonInput]` 与 `garmentInputs: [GenerationGarmentInput]` 均由 GenerationRecord `.cascade` 删除。GenerationRecord 不因源人物或衣物删除而删除。

主状态转换：`queued → preparing → running → succeeded | failed`；任何非终态都可因用户或系统取消进入 `cancelled`。终态不可改回运行态；重新生成必须创建新记录。

### 3.7 GenerationPersonInput

用于保存生成时的人物输入快照，避免历史依赖当前可变数据。

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 子项 ID |
| `generation` | `GenerationRecord` | 否 | 无 | 所属记录 |
| `personProfile` | `PersonProfile` | 是 | `nil` | 当前关系，删除规则 `.nullify` |
| `personProfileID` | `UUID` | 否 | 无 | 当时人物 ID |
| `personNameSnapshot` | `String` | 否 | `""` | 当时名称 |
| `personImage` | `PersonImage` | 是 | `nil` | 当前图片关系，删除规则 `.nullify` |
| `personImageID` | `UUID` | 否 | 无 | 当时图片 ID |
| `resourceIDSnapshot` | `String` | 否 | 无 | 当时发送所依据的资源 ID |
| `sortOrder` | `Int` | 否 | `0` | 多参考图顺序 |
| `createdAt` | `Date` | 否 | 当前时间 | 创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 修改时间，通常与创建相同 |

### 3.8 GenerationGarmentInput

| 字段 | 类型 | 可选 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | `UUID` | 否 | 新 UUID | 子项 ID |
| `generation` | `GenerationRecord` | 否 | 无 | 所属记录 |
| `clothingItem` | `ClothingItem` | 是 | `nil` | 当前关系，删除规则 `.nullify` |
| `clothingItemID` | `UUID` | 否 | 无 | 当时衣物 ID |
| `clothingNameSnapshot` | `String` | 否 | `""` | 当时名称 |
| `categoryCodeSnapshot` | `String` | 否 | `other` | 当时分类 |
| `slotCode` | `String` | 否 | 无 | 当时试穿槽位 |
| `resourceIDSnapshot` | `String` | 否 | 无 | 当时发送所依据的资源 ID |
| `sortOrder` | `Int` | 否 | `0` | 同槽位顺序 |
| `createdAt` | `Date` | 否 | 当前时间 | 创建时间 |
| `updatedAt` | `Date` | 否 | 当前时间 | 修改时间，通常与创建相同 |

## 4. 枚举与稳定 code

以下是领域层枚举建议；持久层保存右侧 code，不保存本地化文字。

```swift
enum ClothingCategory: String, CaseIterable, Sendable {
    case tops = "tops"
    case outerwear = "outerwear"
    case bottoms = "bottoms"
    case dresses = "dresses"
    case footwear = "footwear"
    case accessories = "accessories"
    case other = "other"
}

enum ClothingSubcategory: String, CaseIterable, Sendable {
    case tshirt = "tshirt"
    case shirt = "shirt"
    case sweater = "sweater"
    case jacket = "jacket"
    case coat = "coat"
    case pants = "pants"
    case shorts = "shorts"
    case skirt = "skirt"
    case onePiece = "one_piece"
    case sneakers = "sneakers"
    case boots = "boots"
    case bag = "bag"
    case hat = "hat"
    case jewelry = "jewelry"
    case other = "other"
}

enum Season: String, CaseIterable, Sendable {
    case spring = "spring"
    case summer = "summer"
    case autumn = "autumn"
    case winter = "winter"
    case allSeason = "all_season"
}

enum StyleTag: String, CaseIterable, Sendable {
    case casual = "casual"
    case formal = "formal"
    case business = "business"
    case sporty = "sporty"
    case street = "street"
    case minimalist = "minimalist"
    case vintage = "vintage"
    case outdoor = "outdoor"
    case other = "other"
}

enum GenerationStatus: String, Sendable {
    case queued = "queued"
    case preparing = "preparing"
    case running = "running"
    case succeeded = "succeeded"
    case failed = "failed"
    case cancelled = "cancelled"
}

enum TryOnSlot: String, CaseIterable, Sendable {
    case upperBody = "upper_body"
    case outerwear = "outerwear"
    case lowerBody = "lower_body"
    case footwear = "footwear"
    case accessories = "accessories"
}
```

颜色未来可提升为独立稳定 code 表；V1 可以由预设 code 与用户自定义值共同组成。未知枚举 code 不应在保存时自动重写为 `other`，以免丢失来自新版本的数据。

## 5. 删除规则摘要

| 父对象 | 子对象/引用 | 规则 | 原因 |
| --- | --- | --- | --- |
| PersonProfile | PersonImage | cascade | 图片只属于该人物；永久删除由 Service 协调资源 |
| Outfit | OutfitItem | cascade | 子项没有独立生命周期 |
| ClothingItem | OutfitItem.clothingItem | nullify | 保留穿搭占位与快照 |
| GenerationRecord | GenerationPersonInput / GenerationGarmentInput | cascade | 输入快照只属于生成记录 |
| ClothingItem / PersonImage | Generation input current relation | nullify | 永久保留历史事实与资源快照 |

SwiftData 删除规则只处理元数据关系；文件资源删除必须由 Storage/Deletion Service 显式协调。

## 6. Schema Migration 策略

- 从首个可发布版本开始使用 `VersionedSchema`，例如 `WardrobeSchemaV1`，并配置显式 `SchemaMigrationPlan`。
- 已发布 Schema 类型保持不可变；新字段只在新版本 Schema 中增加。
- 优先使用可推断的轻量迁移：新增字段需提供安全默认值或先设为可选。
- 枚举新增 case 不需要立即迁移，因为持久化的是稳定字符串 code；重命名或合并 code 必须显式迁移。
- 复杂变化采用“新增字段 → 回填 → 切换读取 → 后续版本清理”的多阶段策略，不在一次发布中破坏旧数据。
- 每次迁移都要验证默认人物唯一性、主图唯一性、资源 ID 合法性、生成状态和关系完整性。
- 备份清单记录 `schemaVersion` 与 `storageLayoutVersion`；恢复时先迁移到当前版本，再开放资料库。
- 测试中保留各已发布 Schema 的小型 fixture，覆盖升级、失败回滚和未知枚举 code。

## 7. 产品能力覆盖检查

| 产品能力 | V1 数据承载 |
| --- | --- |
| 衣物资产、分类、搜索与归档 | `ClothingItem` 及分类/季节/风格 code |
| 多人物与多张参考照 | `PersonProfile`、`PersonImage` |
| 试衣槽位 | ViewModel 中的临时 Try-On State；确认生成后写入 `GenerationGarmentInput.slotCode` |
| 保存与收藏穿搭 | `Outfit`、`OutfitItem` |
| 成功、失败、取消与重新生成历史 | `GenerationRecord`、两类 Generation Input 快照、`sourceGenerationID` |
| 图片与生成结果 | 模型中的受控 resource ID；二进制由 Storage Service 保存 |
| Provider、Prompt 与参数 | `GenerationRecord.providerID`、`prompt`、`optionsJSON` |
| API Key | 不进入 SwiftData；由 Keychain `CredentialStore` 管理 |
| 应用设置 | 非敏感偏好由 Settings Repository 管理；需要长期迁移的设置应使用版本化配置结构 |
| 备份与恢复 | 按稳定 UUID、关系和 resource ID 进行逻辑导出，格式见 Storage 规范 |

Future 中的穿着记录、天气推荐、旅行行李箱与同步不在 V1 Schema 中提前建空模型；引入时通过新 VersionedSchema 增量扩展。
