# 架构设计

## 1. 架构目标

应用采用本地优先、分层、依赖可替换的原生 macOS 架构。核心目标是让 SwiftUI、SwiftData、文件系统和 AI Provider 各自具有清晰边界，使数据迁移、测试和未来平台扩展不依赖大规模重写。

首选技术为 Swift、SwiftUI、SwiftData 和 Swift Concurrency（`async/await`、`Actor`）。第三方依赖应谨慎引入，并在架构决策记录中说明必要性。

## 2. 建议目录与模块

初期可在单一 Xcode App target 内使用清晰目录和访问控制；只有当编译边界、复用或测试价值明确时再拆分 Swift Package，避免过早模块化。

```text
WardrobeApp/
├── App/
│   ├── WardrobeApp.swift
│   ├── AppEnvironment.swift
│   └── AppRouter.swift
├── Features/
│   ├── Wardrobe/
│   ├── Person/
│   ├── TryOn/
│   ├── Outfit/
│   ├── GenerationHistory/
│   └── Settings/
├── Domain/
│   ├── Models/
│   ├── Repositories/
│   └── Services/
├── Core/
│   ├── Database/
│   ├── Storage/
│   ├── ImageProcessing/
│   ├── Networking/
│   ├── Security/
│   ├── Logging/
│   ├── Backup/
│   └── Utilities/
├── AI/
│   ├── VirtualTryOnProvider.swift
│   ├── VirtualTryOnService.swift
│   ├── Providers/
│   │   ├── OpenAIProvider.swift
│   │   ├── SpecializedVTONProvider.swift
│   │   ├── LocalProvider.swift
│   │   └── MockProvider.swift
│   └── Models/
└── Resources/
```

`OpenAIProvider` 等目录仅表示扩展位置，不代表 V1 规划阶段已实现或已选择具体服务。

## 3. 依赖方向

```text
App composition root
        ↓
Features (View + ViewModel/State)
        ↓
Domain use cases / repository protocols
        ↓
Core implementations and AI abstractions
        ↓
SwiftData / file system / Keychain / provider SDK or HTTP
```

- Feature 不依赖具体 Provider、SwiftData `ModelContext`、Keychain 或文件路径。
- Domain 定义业务用例、领域值和 Repository 协议，不依赖 UI。
- Core 提供 Repository、Storage、Security、Backup 等实现。
- AI 模块依赖领域请求模型和必要的基础设施协议；具体 Provider 不能反向渗透到 Feature。
- App 是组合根，负责创建依赖并注入 Feature。禁止使用可变全局单例充当依赖容器。

## 4. 各层职责

### 4.1 View

- 声明布局、控件、焦点、菜单、拖放、可访问性和状态呈现。
- 将用户意图转换为 ViewModel 方法调用。
- 只持有展示所需的轻量状态，不直接执行查询、保存、图片处理、文件操作、Keychain 或网络调用。
- 不直接持有或使用 `ModelContext`；预览通过 Mock Repository/ViewModel 数据运行。

### 4.2 ViewModel / Feature State

- 建议标注 `@MainActor`，管理加载、空态、选择、编辑草稿、错误提示和异步任务生命周期。
- 调用领域用例或 Repository 协议，转换领域结果为展示状态。
- 管理 Try-On Slot、搜索条件、排序和拖放意图，但不解析供应商响应或拼接文件路径。
- 负责取消离开页面后不再需要的任务，避免持有 View 或平台服务的隐式全局引用。

### 4.3 Repository

- 对 Feature 提供面向业务的读取与写入接口，例如衣物查询、穿搭保存、生成记录更新。
- 封装 SwiftData 查询、关系和事务边界；将持久化错误映射为稳定的应用错误。
- 对涉及数据库与文件的操作调用协调 Service，不独自假设文件操作一定成功。
- Repository 协议位于 Domain，实现位于 Core/Database；优先使用依赖注入以便内存实现和测试替身。

### 4.4 Service / Use Case

- 编排跨 Repository、Storage、Image Processing、AI、Keychain 或 Backup 的业务流程。
- 例如 `ImportClothingService` 负责验证输入、写入资源、生成缩略图、保存元数据和失败补偿。
- `VirtualTryOnService` 负责校验槽位、创建生成记录、准备 Provider 输入、调用 Provider、保存结果并更新状态。
- 并发敏感服务优先使用 `actor` 或明确隔离；UI 更新回到 `MainActor`。

### 4.5 Storage

- `StorageService` 是 Application Support 中持久资源的唯一入口。
- 负责生成受控资源 ID、路径解析、原子写入、读取、移动、删除、校验、容量统计和临时文件生命周期。
- 外层只保存和传递资源 ID，不拼接绝对路径。详细规则见 [STORAGE_SPEC.md](STORAGE_SPEC.md)。
- 当前实现为通过 `StorageServing` 注入的 `StorageService` actor，同一实例串行化 owner 写入。`StorageResourceID` 只接受批准的顶级目录、小写规范 UUID 和固定文件种类，解码持久引用时会重新验证。
- 基础 `ImageIOThumbnailGenerator` 只负责格式/尺寸验证、方向修正降采样和 JPEG 编码；StorageService 负责 staging、目标命名和发布。Stage 3 在该边界上扩展完整 processed image pipeline，不把图片逻辑放入 View 或 Repository。
- Stage 3 由 `ImageProcessingServing`/`ImageProcessingService` 提供 async 图片标准化入口，`ImageProcessingPreset` 显式区分 garment、person 与预留 generated result 策略；Feature 不接触 ImageIO、文件 URL 或 magic number。生产实例只依赖窄接口 `ImageProcessingStorageServing` 与 `BackgroundRemovalProviding`，不依赖 SwiftUI、SwiftData Repository、AI Provider 或衣服 CRUD。
- `ImageProcessingService` 请求 Storage 创建受控 staging workspace，在 detached worker 中以 ImageIO 先校验再按目标尺寸降采样、修正 orientation、绘制到 sRGB、编码 processed PNG 和 thumbnail JPEG，最后回到 Storage actor 发布。Task cancellation 在各重处理边界传播为 `CancellationError`；取消/失败只清理当前 operation，不发布半成品。
- `BackgroundRemovalProviding` 当前注入 `DisabledBackgroundRemovalProvider`，行为是 deterministic no-op 且无网络依赖；未来 Apple Vision、AI 或测试 provider 可在不改变 Feature/Storage 边界的情况下替换。Stage 3 不提供真实背景分离。
- pipeline constant `wardrobe-image-v1` 同时出现在结果 metadata 与 PNG `Software` 字段。已发布 `processed.png` 默认不可覆盖；未来重新处理由生命周期 Service 在引用预检后采用版本化资源策略，不能由图片层自行删除或替换历史引用。
- `StorageCompensationTransaction` 为跨 SwiftData/filesystem Service 提供显式补偿记录；它只回滚调用方注册的本次资源，不执行全库扫描。

### 4.6 AI Provider

- `VirtualTryOnProvider` 描述能力、验证配置并执行单次虚拟试穿请求。
- 具体 Provider 封装鉴权、请求构造、网络协议、响应解析和供应商错误。
- Provider 不更新 SwiftData、不决定 UI、不直接管理历史记录；这些由 `VirtualTryOnService` 编排。
- API Key 通过 `CredentialStore` 的 Keychain 实现按需提供，不能进入 Provider 配置文件或日志。

### 4.7 Stage 4 衣橱业务边界

- `WardrobeView` 只依赖 `WardrobeViewModel`；ViewModel 只调用 `ClothingManagementService`、`ImportClothingService`、`ClothingDeletionService` 与只读 `ClothingImageLoading`。
- `ImportClothingService` 在 MainActor 上协调 Repository 状态，并 await Storage actor 与 detached ImageProcessing worker：先生成稳定 Clothing UUID，再导入 original、生成 processed/thumbnail、最后提交 SwiftData。数据库提交前任一步失败都会删除本次明确 owner 目录；cleanup issue 单独返回，不覆盖主错误。
- `ResourceReferenceInspector` 从 Repository 获取全模型持久资源引用集合，覆盖 Clothing、Person、Outfit 与 Generation 的当前引用和 snapshot 字段。它不是 Clothing 三列的专用检查器，可供后续人物、穿搭与历史删除流程复用。
- `ClothingDeletionService` 先收集候选和影响摘要，再删除并保存 metadata；SwiftData `.nullify` 保留 Outfit/Generation snapshot。保存成功后才检查 surviving references：任一候选仍被引用时保留完整 owner 目录，全部无引用时才请求受控目录删除。cleanup 失败不回滚已安全提交的数据库状态。
- `AppEnvironment` 不再向 Feature 暴露完整 `StorageServing` 或 `ImageProcessingServing`。组合根把具体 Storage 拆成导入、删除与只读图片加载窄能力并只注入 Service；Wardrobe Feature 无法取得 `deleteResourceDirectory`。

### 4.8 Stage 5 人物业务边界

- `PersonView` 只依赖 `PersonViewModel`；ViewModel 分别调用 `PersonManagementService`、`ImportPersonImageService`、`PersonImageDeletionService`、`PersonProfileDeletionService` 与只读 `PersonImageLoading`。
- `ImportPersonImageService` 以稳定 PersonImage UUID 作为 Storage owner，编排 staging import、Stage 3 `.person` preset、SwiftData 保存和失败补偿；档案本身可先于图片独立创建。
- `PersonManagementService` 负责档案 CRUD、归档、Default/Primary 命令与 `PersonReferenceSet` 查询。Repository 在 MainActor 上串行维护全局 active default 和档案内 primary 唯一性，Feature 不直接遍历 SwiftData relationship 为 AI 选择素材。
- 两类人物删除 Service 都在 metadata 提交前收集完整候选资源，提交 cascade/nullify 后复用 `ResourceReferenceInspector` 检查 surviving references，并按 PersonImage owner 独立决定是否删除目录。cleanup failure 单独报告，不回滚已经一致的数据库状态。
- `AppEnvironment` 只向 Person Feature 注入上述用例与只读加载器；完整 Storage 和 ImageProcessing 仍只存在于 composition root。

### 4.9 Stage 6 AI Provider 基础边界

- AI 层定义 `VirtualTryOnProvider` 和全套 Provider 中立、`Sendable` 的请求/结果/能力/错误类型；不依赖 SwiftUI、SwiftData、Storage 路径、Keychain、网络框架或任何供应商 SDK。
- `VirtualTryOnRequestValidator` 集中验证 capability 定义、人物/衣物图片、语义槽位、数量、格式、尺寸、版本化选项及 Provider 参数 allowlist。Feature 和具体 Adapter 不复制这些通用规则。
- `TryOnPromptBuilder` 输出带版本的 Provider 中立 Prompt；日志层没有接收图片字节或完整 Prompt 的接口。
- `ProviderRegistry` 由 `AppEnvironment` 持有并在 composition root 注册 Provider；actor 提供并发安全的只读选择，不使用全局可变单例。当前只注册无网络的 `MockVirtualTryOnProvider`。
- Mock Provider 以注入行为模拟确定性成功、瞬时失败、永久失败、延迟与取消，不写 GenerationRecord、不访问 Storage。完整生成持久化仍属于 Stage 10，试衣 UI 属于 Stage 7。

### 4.10 Stage 7 试衣工作区边界

- `TryOnSession` 是 MainActor Feature 所拥有的 transient UUID 状态：人物、明确选择的人物图片及五类语义槽位；不写入 SwiftData，也不修改 `ClothingItem`、`PersonProfile` 或 `PersonImage` 来表达当前选择。
- `ClothingToTryOnSlotMapper` 集中映射 tops/outerwear/bottoms/footwear/accessories；dresses、other 与未知 code 明确返回 unsupported。单值槽位原子替换，Accessories 多值且保持稳定顺序。
- Try-On 复用 Stage 4 `ClothingManagementService` 的 active query 和 Stage 5 `PersonManagementService` 的 Default/Primary reference 规则。按 profile UUID 查询 reference set 是 Stage 5 use case 的兼容扩展，View 不遍历 SwiftData relationship。
- `VirtualTryOnRequestBuilder` 通过只读 `TryOnResourceLoading` 获取受控资源；人物与衣物均采用 processed→original，解码后创建短生命周期 `ProviderImage`。Feature 没有目录删除、写入或路径解析能力。
- `TryOnViewModel` 管理 idle/validating/generating/success/failure/cancelled，并以 token 丢弃取消或人物切换后的迟到结果。Stage 7 不创建 GenerationRecord，不保存 Mock result。

### 4.11 Stage 8 外部 ChatGPT 交接边界

- 外部交接与 Provider generation 并列：`TryOnViewModel → ExternalGenerationWorkflow → ExternalGenerationPackageBuilder → Clipboard/Launcher/Finder`。它不实现或伪装成 `VirtualTryOnProvider`，Stage 6 registry 与 Mock 保持不变。
- PackageBuilder 只依赖 `TryOnResourceLoading` 和 `ExternalGenerationWorkspaceServing`，没有正式资源删除、SwiftData、网络或任意路径写入能力。导出始终 copy processed→original，不 move/改写源资源。
- `ExternalGenerationWorkspace` 只在受控 `external-generations/ChatGPT-TryOn-<UUID>/` 发布 package；绝对目录仅存在于 transient package handle，manifest 和数据库不保存绝对路径。
- `ClipboardServing` 与 `ExternalAILaunching` 可注入。生产实现使用 `NSPasteboard`、`NSWorkspace`、ChatGPT app bundle lookup、正常 Web fallback 和 Finder reveal；失败只形成可恢复提示，不销毁 package。
- `ExternalGenerationResultImporter` 是独立边界，真实解码用户选择的图片后调用窄的 generation result Storage 能力，再保存 V1 GenerationRecord 与输入快照；数据库失败会补偿删除本次 generation owner，不触碰人物、衣物或 package 外资源。
- Stage 8 未实现 Accessibility auto-fill。若未来加入，必须作为默认关闭的实验 adapter，失败回退到上述稳定流程，且永远不执行 Send。

### 4.12 Stage 10 Provider 生成编排边界

- `VirtualTryOnService` 由 composition root 注入 Repository、窄的 generation result Storage、`VirtualTryOnRequestBuilder` 与 Provider；Try-On ViewModel 只提交 Session 意图并展示状态/结果，不接触 SwiftData、文件路径或 destructive Storage。
- Service 在图片读取和 Provider 调用前创建 `queued` GenerationRecord 与不可变人物/衣物快照，再按 `preparing → running → terminal` 更新；每次 Provider 调用前持久化 `attemptCount`，仅对明确的 `transientFailure` 在同一记录内做最多两次尝试。
- Provider 成功结果先由 Storage staging、真实图片校验、缩略图生成和原子发布，再提交资源 ID 与 `succeeded`。若终态数据库提交失败，Service 只补偿删除本次 generation owner；失败和取消保留记录，但不保留半成品结果。
- Regenerate 复用同一 Service 并创建新 UUID，通过 `sourceGenerationID` 指向来源，不修改旧记录。应用 composition root 打开资料库后运行 `InterruptedGenerationRecoveryService`，将遗留的 `queued/preparing/running` 记录标为脱敏的 `failed/interrupted`。
- 当前生产方向仍是 Stage 8 External ChatGPT 手动交接；Stage 10 的 UI 入口仅在 Debug 暴露 Mock 完整链，不新增 API、凭据、网络或付费 Provider，也不实现 Stage 12 历史浏览。

### 4.11 Stage 11 穿搭业务边界

- `OutfitView` 只依赖 `OutfitViewModel`；ViewModel 调用 `OutfitService` 和只读 `ClothingImageLoading`。Feature 使用 `OutfitRecord`/`OutfitItemRecord`，不接触 SwiftData model 或 `ModelContext`。
- `OutfitService` 复用 `TryOnSession`/`TryOnSlot`，负责空搭配、单值槽唯一、Accessories 连续顺序、保存 snapshot 和 load preflight；Repository 负责 query、稳定排序、关系映射与事务提交。
- `TryOnWorkspaceCoordinator` 由 App Shell 明确持有，不是 singleton。Outfit 先生成显式 `OutfitLoadResult`，Shell 导航到 Try-On，工作区消费一次性请求并仅替换衣物槽位，人物选择保持不变。
- Outfit 卡片与详情只用 current thumbnail 或 snapshot thumbnail 的只读加载；没有自动生成 cover。永久删除只删除 Outfit metadata/cascade items，不取得 Storage 删除能力。

## 5. 关键流程

### 5.1 导入衣物

1. ViewModel 收集编辑草稿并调用导入用例。
2. 用例验证元数据和输入图片。
3. Storage 创建 owner UUID 对应的临时目录并原子写入原图。
4. Stage 2 先生成基础 thumbnail 并保留 processed 受控位置；Stage 3 的 Image Processing 再生成版本化 processed 产物并可扩展 thumbnail 策略。
5. Repository 保存仅含资源 ID 的 `ClothingItem`。
6. 若数据库保存失败，Service 删除本次新建的明确资源；若清理失败，记录为可扫描孤儿，不隐藏主错误。

### 5.2 AI 生成

1. Try-On ViewModel 将人物图片、槽位和选项交给 `VirtualTryOnService`。
2. Service 创建状态为 `queued` 的 `GenerationRecord` 及不可变输入快照。
3. Service 通过 Storage 解析输入并转换为 Provider 中立的 payload。
4. Provider 执行请求；Service 根据结果更新 `running`、`succeeded`、`failed` 或 `cancelled`。
5. 成功结果先原子写入 generation 资源目录，再保存结果资源 ID。
6. 重新生成重复上述流程并写入 `sourceGenerationID`，不修改旧记录。

### 5.3 删除

- 普通用户操作优先设置 `archivedAt`，不立即删除资源。
- 永久删除由专用 Service 计算影响范围、确认引用、更新数据库后逐个删除明确资源。
- OutfitItem 和生成输入保留 UUID 与名称快照；关系可置空，不让历史记录被级联删除。

## 6. 错误、日志与隐私

- 对用户显示可操作的领域错误，对日志保留底层原因和关联 ID。
- 使用统一 Logger 分类；禁止记录 API Key、Authorization header、完整 Prompt 中的敏感信息、图片二进制或用户目录绝对路径。
- 错误类型区分验证、存储、数据库、凭据、网络、Provider、取消和备份恢复。
- 可恢复错误提供重试；不可恢复错误说明下一步。取消不是失败，不触发无条件重试。

## 7. 测试策略

- Domain/Service 单元测试：状态转换、删除规则、重新生成链、迁移默认值和错误映射。
- Repository 测试：使用内存 SwiftData container 验证查询、关系和删除规则。
- Storage 测试：使用每个测试独立的临时根目录验证路径逃逸、原子写入、清理与恢复。
- AI 测试：默认使用 `MockProvider`，覆盖成功、失败、延迟和取消；自动测试不得调用真实付费 API。
- UI 测试：覆盖主导航、衣物编辑、槽位拖放语义、生成状态和危险操作确认。
- Migration 测试：保留旧 Schema fixture，验证逐版本迁移和资源引用不变。

## 8. 架构演进规则

- Schema 使用显式版本和分阶段 Migration Plan，禁止直接修改已发布版本定义。
- 公共协议的新增能力优先采用新类型、默认行为或 capability negotiation，避免破坏既有 Provider。
- 大型重构必须由实际痛点驱动，并拆成可验证的小步骤。
- 任何影响此边界的变更必须同步更新本文及相关专项文档。
