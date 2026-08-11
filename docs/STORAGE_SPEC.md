# 文件与图片存储规范

## 1. 目标与边界

SwiftData 保存元数据和资源 ID；原始图片、处理后图片、缩略图、AI 生成结果与备份保存在 Application Support。任何 Feature、View 或 Repository 都不得自行拼接绝对路径，所有持久文件操作统一通过 `StorageService`。

V1 的资料库根目录建议为：

```text
~/Library/Application Support/<bundle-identifier>/Wardrobe/
```

真实根路径可能因 App Sandbox container 变化，因此数据库只能保存相对于 `Wardrobe/` 的受控资源 ID。

当前实现通过 `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)` 获取根位置，并使用 bundle identifier `com.lishunjie.Wardrobe` 组成应用专属目录。生产数据库位于 `Wardrobe/database/WardrobeV1.store`；测试通过依赖注入或 Debug 测试进程覆盖使用独立临时根，不访问真实 Application Support。

## 2. 目录布局

```text
Wardrobe/
├── library.json
├── database/
│   └── SwiftData managed files
├── garments/
│   └── <ClothingItem UUID>/
│       ├── original.<validated-extension>
│       ├── processed.png
│       └── thumbnail.jpg
├── persons/
│   └── <PersonImage UUID>/
│       ├── original.<validated-extension>
│       ├── processed.png
│       └── thumbnail.jpg
├── generations/
│   └── <GenerationRecord UUID>/
│       ├── result.<validated-extension>
│       └── thumbnail.jpg
├── outfits/
│   └── <Outfit UUID>/
│       └── cover.jpg
├── staging/
│   └── <Operation UUID>/
├── cache/
│   ├── previews/
│   └── provider/
└── backups/
    └── <timestamp>-<Backup UUID>.wardrobebackup
```

- `library.json` 仅记录资料库格式、`storageLayoutVersion` 和非敏感标识，不复制业务数据。
- `database/` 由 SwiftData container 管理，应用不得直接修改其内部文件。
- owner 目录只使用规范化小写 UUID 字符串；文件名由 Storage Service 的资源种类决定，不接受任意用户输入。
- 当前 `storageLayoutVersion` 为 `1`。`library.json` 包含该版本、稳定 `libraryID` 与创建时间；重复初始化保持 manifest 不变，遇到不支持版本时拒绝开放资料库。

## 3. 资源 ID

`StorageResourceID` 是相对 `Wardrobe/` 的逻辑标识，例如：

```text
garments/4f8b.../original.heic
persons/b670.../processed.png
generations/89a1.../result.png
```

约束：

- 必须由 Storage Service 创建或验证，使用 `/` 作为逻辑分隔符。
- 禁止绝对路径、`..`、符号链接逃逸、空路径、未批准的顶级目录和控制字符。
- 解析后标准化 URL 必须仍位于当前资料库根目录内。
- 数据库保存资源 ID 字符串；外部导入源 URL 仅在导入操作期间存在，不持久化。
- 资源 ID 在资料库迁移和备份恢复后保持不变；只有根目录解析结果改变。

## 4. 各类文件

### 4.1 原始图片

- 导入后按原始可识别格式保存，保留可用元数据但不得信任扩展名；通过图像解码和 MIME/UTType 校验真实格式。
- 原始图片是用户资产，默认进入完整备份，不受缓存清理影响。
- 导入时复制到 staging，完成校验后原子移动到 owner 目录。

### 4.2 处理后图片

- 用于 AI 输入或一致显示的标准化版本。Stage 3 的正式格式为 PNG，pipeline version 为 `wardrobe-image-v1`；输出固定为 orientation `up`、8-bit sRGB，不保留 EXIF、相机、定位或来源色彩 metadata，只在 PNG `Software` 字段写入非敏感 pipeline version。
- `original` 是不可破坏的源素材。处理过程只从 Storage 签发的只读 staging 副本解码，绝不修改或覆盖 original resource。
- `garment` preset 最长边为 `2048` px，保持宽高比、不裁剪并保留 alpha，为未来背景去除保留透明通道；当前背景去除 provider 为 deterministic disabled/no-op，不调用网络。
- `person` preset 最长边为 `4096` px，保持宽高比、不裁剪，透明区域合成到白色并输出不带 alpha 的 PNG，避免人物参考图发生意外透明；该 preset 以保留 AI reference detail 为优先。
- `generatedResult` preset 预留最长边 `3072` px、保留 alpha；Stage 3 不接入生成业务流程。
- 它是派生资产但可能被历史请求的 `resourceIDSnapshot` 引用，因此不能被普通缓存清理删除。
- Stage 3 对已经存在的 `processed.png` 拒绝覆盖，确保固定 resource ID 不被静默改变；PNG 内嵌版本可在重启后识别生成算法。未来重新处理必须由衣服/人物生命周期 Service 先做 surviving-reference 预检，再通过新的受控版本资源命名或 Storage layout migration 发布；Stage 3 不提前实现该业务协调，也不修改 `WardrobeSchemaV1`。

### 4.3 缩略图

- V1 建议 JPEG，使用固定最大像素边和质量配置，保留正确方向。
- 业务 owner 下的 thumbnail 是持久派生资源，可随完整备份保存，也可在恢复后重建。
- `cache/previews` 中的临时缩略图是可删除缓存，不进入备份。
- Stage 2 基础实现使用 ImageIO 从文件 URL 降采样，最大边 `512` 像素，JPEG quality `0.82`，并启用 orientation transform。该实现避免为生成缩略图先完整解码原图；Stage 3 可在不改变资源 ID 和 Storage 边界的前提下扩展色彩空间、处理版本和更完整的图片流水线。
- Stage 3 canonical pipeline 由同一次受限 processed decode 派生 JPEG thumbnail，最长边仍为 `512` px、不裁剪、orientation `up`、sRGB/不带 alpha。`garment` quality 为 `0.82`，`person` 为 `0.86`，预留的 `generatedResult` 为 `0.84`。若 Stage 2 导入已生成基础 thumbnail，Storage 仅在 processed 与新 thumbnail 均校验成功后替换它；失败时恢复旧 thumbnail。

### 4.4 AI 生成图

- 成功响应先写入 `staging/<Operation UUID>/`，验证可解码、尺寸和大小后原子移动到 `generations/<GenerationRecord UUID>/result.*`。
- 生成结果属于用户历史资产，默认进入完整备份，不作为普通 Cache 清除。
- 同一 GenerationRecord 只对应一个不可变结果；重新生成创建新的 UUID 目录。

### 4.5 临时文件

- `staging/` 仅保存进行中的导入、导出、恢复和生成操作。
- 文件使用 Operation UUID 隔离，并在成功或失败后删除明确操作目录中的文件；启动时可清理超过安全期限且没有活动操作标记的 staging 内容。
- 系统临时目录可用于不需要跨启动恢复的瞬时数据，但不得作为持久资源地址。

### 4.6 Cache

- 仅保存可从持久数据或远端响应重新构建的内容。
- Cache 需要版本、容量上限和最近访问清理策略；清理 Cache 不更新 SwiftData 业务记录。
- 清理动作不得遍历删除未经 Storage Service 验证的路径。

## 5. 写入一致性

- 所有写入采用“staging 写入 → 校验 → 原子移动 → 元数据提交”的流程。
- 涉及文件和 SwiftData 的操作由 Service 建立补偿步骤，因为二者不共享事务。
- 新资源写入成功但数据库保存失败时，删除本次操作创建的明确资源。
- 数据库提交成功但后续清理失败时，保留一致的业务状态并记录待清理项，不回滚成悬空引用。
- 同一 owner 的并发写入由 Storage actor 串行化；文件替换使用临时文件与原子 rename。
- Stage 3 通过 `ImageProcessingStorageServing` 请求受控 workspace：Storage 把 original 复制到 `staging/<Operation UUID>/input.*`，处理器只写固定的 `processed.png` 与 `thumbnail.jpg`。发布在 Storage actor 内完成；发布前失败或取消只删除该 operation，发布中错误回滚新 processed 并恢复旧 thumbnail，不向图片服务暴露通用删除 API。
- 新 owner 的图片导入在 `staging/<Operation UUID>/` 内完成真实格式检测、原图复制、再次解码校验和 thumbnail 生成，再将整个操作目录原子 rename 为 owner 目录。失败只清理该 operation 与本次明确 owner，不扫描或删除其他资源。
- 跨 SwiftData 与文件系统的上层 Service 使用 `StorageCompensationTransaction` 记录本次创建的明确 resource/owner；Repository save 成功后 commit，失败则按逆序 rollback。清理失败作为独立 issue 返回，不能覆盖原始业务错误。

### 5.1 导入验证基线

- 接受 ImageIO 实际解码为 JPEG、PNG、HEIC 或 HEIF 的单帧/首帧图片；持久扩展名来自检测结果，不信任来源文件名。
- 单文件上限为 100 MiB，首帧像素总数上限为 100,000,000，且宽高必须为正数。
- 当前自动测试运行时可稳定编码/解码 JPEG、PNG、HEIC；HEIF encoder 不可用时测试明确 skip，不将其伪报为成功。运行时导入仍支持系统 ImageIO 能解码的 HEIF。

### 5.2 Stage 3 解码与内存基线

- pipeline 在创建 bitmap 前复用 100 MiB、100,000,000 pixel 和真实格式校验；像素乘法使用 overflow-safe 计算。
- 生产处理不把 original 读成 `Data`，而是从受控 file URL 使用 `CGImageSource` 且关闭 source cache；`CGImageSourceCreateThumbnailAtIndex` 同时完成 orientation transform 与目标最长边降采样，避免先建立 full-resolution bitmap。
- 峰值长期对象限于一个 preset 尺寸的 sRGB processed bitmap 和一个 512 px thumbnail bitmap；original、processed 与 thumbnail 不会作为三个完整 bitmap 同时驻留。
- CPU/解码/编码工作在 detached worker 上执行，不占用 SwiftUI MainActor；在校验、降采样、可选背景处理、颜色转换、两次编码和发布前检查 Task cancellation。

## 6. 删除与孤儿清理

### 6.1 用户删除

- 归档只更新 `archivedAt`，不删除文件。
- 永久删除前，Deletion Service 汇总 Outfit 和 Generation 引用，并向用户说明影响。
- 历史快照仍引用的资源不得直接删除。V1 可保留原 owner 目录中的具体资源文件，即使 owner 元数据已永久删除；未来若迁移为 generation-owned snapshot，必须先复制、校验并更新资源 ID，再删除旧文件。
- 资源是否可删除以所有元数据中的资源 ID 引用为准，而不是仅看 owner 对象是否存在。删除最后一条历史或穿搭引用后，资源才进入带宽限期的孤儿清理候选。
- 永久删除先更新/删除元数据关系，再逐个删除已确认的文件；失败文件登记为待清理孤儿。
- Stage 4 的 `ResourceReferenceInspector` 在 metadata 删除提交后检查全部 V1 持久模型中的资源字段与 snapshot 字段。只要同一 garment owner 的任一候选资源仍被引用，就保守保留完整 owner 目录；只有 original、processed、thumbnail 均无 surviving reference 时才允许目录级清理。
- Stage 5 的每张人物照片以 PersonImage UUID 作为独立 owner。删除单张图片或 cascade 删除 PersonProfile 前先收集每张图片的 original、processed、thumbnail；metadata 提交后逐 owner 检查 surviving references。某 owner 任一资源仍被 Generation snapshot 引用时保留该 owner 完整目录，未被引用的其他 PersonImage owner 可独立清理。
- 删除后的文件 cleanup 不参与 SwiftData 回滚：cleanup failure 作为独立结果报告，避免把已经 nullify 且保存的历史关系恢复成更危险的跨存储不一致状态。

### 6.2 孤儿扫描

- 扫描器比较数据库声明资源与 Storage 目录，但只生成报告，默认不自动永久删除。
- 区分“数据库引用缺失文件”和“文件无数据库引用”：前者优先报告数据损坏，后者在宽限期后才允许清理。
- 任何自动清理都应限制在已验证 owner 目录、具备宽限期并产生脱敏日志。

## 7. 备份与恢复

### 7.1 备份格式

V1 使用应用控制的版本化 `.wardrobebackup` 包，而不是把运行中的 SwiftData SQLite 文件直接复制出来。包至少包含：

```text
manifest.json
metadata/records.json
assets/...
checksums.json
```

- `manifest.json` 包含应用版本、schemaVersion、storageLayoutVersion、创建时间、记录数和格式版本。
- `records.json` 是稳定、可迁移的逻辑导出，不暴露 SwiftData 内部标识。
- `assets` 按资源 ID 保留相对布局。
- `checksums.json` 用于恢复前完整性验证。
- API Key、Keychain 内容、日志、staging 和可重建 Cache 永不进入备份。

### 7.2 恢复流程

1. 在 staging 中打开备份，校验格式、路径、校验和、可用空间与支持的版本。
2. 将逻辑记录迁移到当前 Schema，并检查 UUID、关系和资源 ID 冲突。
3. 恢复前创建当前资料库的可回滚快照。
4. 在隔离的新资料库根完成数据库与资源导入验证。
5. 原子切换资料库指针或受控替换；失败则回滚，不留下半恢复状态。
6. 首次打开恢复资料库时运行一致性检查。

V1 若只支持替换恢复，UI 必须明确说明；合并恢复需要独立的 UUID 冲突和重复资源策略，不能伪装成简单覆盖。

## 8. 存储迁移

- `storageLayoutVersion` 与 SwiftData schemaVersion 独立演进。
- 路径结构变化采用显式 Storage Migration：预检空间、逐资源复制/移动、校验、更新资源 ID、提交版本、失败回滚。
- 不在应用启动主线程上执行大量迁移；显示进度并阻止同时写入。
- 每次迁移必须可重复检测、支持从中断点恢复，并具备 fixture 测试。
