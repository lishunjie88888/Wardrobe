# Wardrobe Codex Execution Checklist

本文件是 Wardrobe 项目后续开发的唯一主执行清单。产品与设计边界以 `AGENTS.md` 和 `docs/` 为依据；实际阶段状态、阻塞项、验收记录和下一步只在本文件维护。

## 使用规则

- [ ] 开始任何 Stage 前，重新阅读 `AGENTS.md`、本清单和该 Stage 涉及的专项文档。
- [ ] 严格按 Dependencies 执行；前置 Stage 未通过时，不以临时 stub 或绕过边界的方式继续。
- [ ] 每次只推进当前 Stage 范围内的工作，不顺带实现后续功能。
- [ ] checkbox 只有在代码、测试、文档和验收证据均完成后才能勾选。
- [ ] 每个 Stage 记录实际执行的 build/test 命令及结果；无法运行时记录原因和风险。
- [ ] 修复本 Stage 引入的编译错误、测试失败和高风险警告后才能完成 Stage。
- [ ] 架构、Schema、资源布局、Provider 协议或 UI 行为变化时，同步更新对应 `docs/`。
- [ ] 自动测试只使用 Mock Provider；真实 AI 调用必须是显式人工操作，且不得泄露凭据或产生意外费用。
- [ ] 永久删除、恢复、迁移和清理属于高风险操作，必须先完成只读预检并经过明确确认。

## Stage 总览

| Stage | 名称 | 核心前置 | 建议人工 Gate |
| --- | --- | --- | --- |
| 0 | 工程基础 | 无 | 是 |
| 1 | 数据模型与持久化 | 0 | 是 |
| 2 | 文件与图片存储 | 0–1 | 是 |
| 3 | 图片处理流水线 | 2 | 否 |
| 4 | 衣橱管理 | 1–3 | 是 |
| 5 | 人物照片管理 | 1–3 | 是 |
| 6 | AI Provider 基础架构 | 0–1 | 是 |
| 7 | AI 试衣间 UI | 4–6 | 是 |
| 8 | 设置与安全 | 2、6 | 是 |
| 9 | OpenAI Provider | 3、6、8 | 是 |
| 10 | AI 生成流程 | 2–3、5–9 | 是 |
| 11 | 穿搭管理 | 4、7 | 否 |
| 12 | 生成历史 | 5、10 | 是 |
| 13 | Schema Migration 加固 | 1、已冻结的 V1 Schema | 是 |
| 14 | 备份与恢复 | 2、12–13 | 是 |
| 15 | UI / UX 打磨 | 4–5、7–8、11–12、14 | 否 |
| 16 | 性能与可靠性 | 10、14–15 | 是 |
| 17 | 完整测试 | 0–16 | 是 |
| 18 | Release 准备 | 17 | 是 |

---

## Stage 0：工程基础

### Goal

建立能持续演进、可构建、可测试的原生 macOS 工程骨架，不实现具体业务功能。

### Scope

- [x] 创建或检查 macOS App Xcode 工程、bundle identifier、部署目标和 Swift 版本。
- [x] 使用 SwiftUI App 生命周期和 `async/await` 可用的最低系统版本。
- [x] 建立 App、Features、Domain、Core、AI、Resources 与 Tests 的基础目录。
- [x] 建立主 App Target、Unit Test Target，必要时建立 UI Test Target。
- [x] 建立 App composition root 和显式依赖注入入口。
- [x] 建立初始 `NavigationSplitView` Shell 与 Sidebar 占位导航。

### Out of Scope

- [x] 不创建 SwiftData 业务模型或业务 Repository 实现。
- [x] 不实现衣橱、人物、试衣、穿搭、设置等业务页面。
- [x] 不接入存储、Keychain、网络或真实 AI API。

### Dependencies

- [x] `AGENTS.md` 与全部规划文档已确认作为工程约束。
- [x] Xcode 与目标 macOS SDK 版本已记录。

### Implementation Tasks

- [x] 创建工程并确认 scheme、Debug/Release configuration 和签名策略。
- [x] 按 `docs/ARCHITECTURE.md` 建立目录和命名空间，不因空目录强行拆 Swift Package。
- [x] 创建最小 `WardrobeApp`、`AppEnvironment` 和导航 route 类型。
- [x] 创建只展示五个 Sidebar 入口的 Shell，占位内容不包含业务逻辑。
- [x] 禁止可变全局单例；在 composition root 注入空实现或协议占位。
- [x] 开启适用的严格并发检查和编译警告策略，并记录暂不能开启的选项。
- [x] 创建基础 Unit Test smoke test；UI Test Target 如建立则添加启动 smoke test。
- [x] 确认项目文件引用与磁盘目录一致，无未归类源文件。

### Tests

- [x] 运行 Debug build。
- [x] 运行 Unit Test Target。
- [x] 如有 UI Test Target，运行 App launch smoke test。
- [x] 手动启动 App，检查主窗口、Sidebar 和基本导航无崩溃。

### Acceptance Criteria

- [x] App 可成功 Build 和启动。
- [x] 测试 Target 可运行并通过。
- [x] 目录与依赖方向符合 `docs/ARCHITECTURE.md`。
- [x] SwiftUI View 中没有数据库、图片、Keychain 或网络逻辑。
- [x] 没有为后续功能加入临时 hack 或假业务实现。

### Documentation Updates

- [x] 记录实际 Xcode、Swift、部署目标、bundle identifier 和 scheme 名称。
- [x] 若目录与规划不同，先更新 `docs/ARCHITECTURE.md` 并说明理由。
- [x] 在本 Stage 下记录 build/test 命令与结果。

### Execution Record（2026-08-10）

- 工具链：Xcode 26.6（17F113）、macOS SDK 26.5、Apple Swift 6.3.3；工程使用 Swift 6 language mode。
- 工程配置：macOS 15.0 deployment target，bundle identifier `com.lishunjie.Wardrobe`，共享 scheme `Wardrobe`，Debug/Release configuration。
- Targets：`Wardrobe` App、`WardrobeTests` Unit Tests、`WardrobeUITests` UI Tests。
- 签名：Automatic；本地构建使用 Xcode 的 ad hoc `Sign to Run Locally`，未配置或提交开发团队凭据。
- 并发与警告：`SWIFT_STRICT_CONCURRENCY = complete`，启用适用的 Clang/Swift 警告；本阶段没有暂缓开启的检查。
- 目录：与 `docs/ARCHITECTURE.md` 规划一致，未发生需要同步文档的结构偏差；Feature 目录仅为后续阶段保留边界，没有业务实现。
- Debug build：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage0DerivedData build` → `BUILD SUCCEEDED`。
- 全部 Stage 0 tests：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage0DerivedData test` → `TEST SUCCEEDED`；2 个 Unit smoke tests 与 1 个 UI launch/navigation smoke test 通过。
- 启动检查：从 Debug 构建产物启动 App，进程稳定运行并可正常退出；UI smoke test 创建主窗口，逐项点击五个 Sidebar 入口并验证对应占位内容，无崩溃。
- 边界审计：App 源码未引用 SwiftData/CoreData、Storage、Keychain、网络或真实 AI API；未创建业务模型、Repository 或业务页面。

### Completion Checklist

- [x] Scope 全部完成，Out of Scope 未被越界实现。
- [x] build/tests 通过且无本 Stage 引入的错误。
- [x] 人工确认 App Shell 与工程结构后，才能进入 Stage 1。

---

## Stage 1：数据模型与持久化

### Goal

建立符合 V1 规格、可迁移且可测试的 SwiftData Schema 与 Repository 基础层。

### Scope

- [x] 实现 `ClothingItem`、`PersonProfile`、`PersonImage`、`Outfit`、`OutfitItem`、`GenerationRecord`。
- [x] 实现 `GenerationPersonInput` 与 `GenerationGarmentInput` 历史快照模型。
- [x] 实现稳定 code 的领域枚举和持久化映射。
- [x] 建立 `WardrobeSchemaV1`、`SchemaMigrationPlan` 基线和 `ModelContainer`。
- [x] 建立 Repository 协议、SwiftData 实现基础和内存测试容器。

### Out of Scope

- [x] 不实现文件写入、图片处理或 UI CRUD。
- [x] 不实现真实迁移到尚不存在的未来 Schema。
- [x] 不将图片 Data、API Key 或绝对路径保存到 SwiftData。

### Dependencies

- [x] Stage 0 已通过。
- [x] `docs/DATA_MODEL.md` 字段、关系和删除规则已复核。

### Implementation Tasks

- [x] 为所有持久模型使用唯一、不可变、应用生成的 UUID。
- [x] 为所有模型实现 `createdAt`、`updatedAt` 及所需 `archivedAt`。
- [x] 按文档实现可选性、默认值、反向关系和 cascade/nullify 删除规则。
- [x] 将可演进枚举持久化为稳定 String code，并保留未知 code。
- [x] 建立默认人物、人物主图和 Try-On Slot 数量约束的 Service/Repository 边界。
- [x] 建立 Generation 状态转换校验，终态不可回到运行态。
- [x] 建立面向业务的 Repository 协议，禁止 Feature 暴露 `ModelContext`。
- [x] 创建生产 `ModelContainer` factory 和测试用 in-memory factory。
- [x] 固化 V1 Schema 定义，禁止后续直接修改已发布版本类型。

### Tests

- [x] 测试每个模型写入、保存、重新 fetch 和更新。
- [x] 测试 PersonProfile→PersonImage 与 Outfit→OutfitItem cascade。
- [x] 测试衣物/人物删除时 OutfitItem 与 Generation input 关系 nullify 且快照保留。
- [x] 测试稳定 UUID、默认值、未知枚举 code 和时间字段。
- [x] 测试默认人物/主图唯一性和 Try-On Slot 约束不只依赖 UI。
- [x] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [x] 模型覆盖 `PRODUCT_SPEC.md` 的 V1 数据需求。
- [x] 可以可靠写入、读取和更新测试数据。
- [x] 删除规则与 `DATA_MODEL.md` 完全一致。
- [x] SwiftData 中不存在完整图片 Data、密钥或绝对路径字段。
- [x] Repository 调用方不需要知道 SwiftData 实现细节。

### Documentation Updates

- [x] 任何字段、关系、默认值或删除规则差异已同步到 `docs/DATA_MODEL.md`。
- [x] 记录 V1 schemaVersion 和 ModelContainer 配置。
- [x] 在本 Stage 下记录测试 fixture 与命令结果。

### Execution Record（2026-08-10）

- Schema：`WardrobeSchemaV1` 的 `schemaVersion` 为 `1.0.0`，包含 8 个 V1 持久模型；`WardrobeMigrationPlan` 仅注册 V1，迁移 stage 为空，作为首个冻结基线。
- ModelContainer：生产配置名为 `WardrobeV1`，使用 SwiftData 默认持久存储位置并在 App composition root 注入；测试配置名为 `WardrobeV1Tests`，使用独立 in-memory store。
- Repository：Domain 定义 Clothing、Person、Outfit、Generation 业务协议；`SwiftDataWardrobeRepository` 在 Core/Database 封装 `ModelContext`，Feature/调用方不接触 SwiftData 查询或事务细节。
- 约束：Repository/Service 边界执行活跃默认人物唯一、每人物主图唯一、单值 Try-On Slot 唯一、Accessories 多值，以及 Generation 终态不可回到运行态；未知枚举 code 保留原始字符串。
- Fixture：每个测试创建独立内存 container，覆盖 8 个模型的写入、保存、重新 fetch、更新、时间字段、稳定 UUID、未知 code、cascade/nullify、历史快照、默认选择、槽位和状态转换。
- Debug build：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage1DerivedData build` → `BUILD SUCCEEDED`。
- 全部 tests：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage1DerivedData test` → `TEST SUCCEEDED`；9 个 Stage 1 persistence tests、2 个既有 Unit smoke tests 与 1 个 UI launch/navigation smoke test 通过。
- 边界审计：持久模型未定义图片 `Data`、API Key 或绝对路径字段；资源引用均为相对 resource ID 字符串；未实现 Stage 2 的文件写入、图片处理或任何业务 CRUD UI。实现字段、默认值和删除规则与 `docs/DATA_MODEL.md` 一致，无需修改专项文档。

### Completion Checklist

- [x] Schema review 完成并冻结 `WardrobeSchemaV1` 基线。
- [x] Repository 与关系测试通过。
- [x] 人工确认删除规则与未来迁移策略后，才能进入依赖此 Schema 的 Stage。

---

## Stage 2：文件与图片存储

### Goal

建立 Application Support 下安全、可迁移、可测试的受控文件存储层。

### Scope

- [x] 实现 `StorageService` 与 `StorageResourceID`。
- [x] 建立 Wardrobe 资料库、garments、persons、generations、outfits、staging、cache、backups 目录。
- [x] 支持原始文件、派生文件和缩略图文件的受控写入/读取位置。
- [x] 实现 Stage 2 导入所需的基础 thumbnail（方向修正、受限降采样与 JPEG 输出），完整 processed pipeline 仍留在 Stage 3。
- [x] 支持 staging、原子移动、明确文件删除和基础 Cache 管理。
- [x] 建立 Storage 与 SwiftData 之间的补偿事务模式。

### Out of Scope

- [x] 不实现 processed image 标准化、色彩空间版本化、背景处理或复杂图片流水线；这些属于 Stage 3。
- [x] 不实现完整业务导入 UI、备份格式或自动孤儿删除。
- [x] 不允许用户任意选择不受控数据根目录。

### Dependencies

- [x] Stage 0–1 已通过。
- [x] `docs/STORAGE_SPEC.md` 的资源布局和生命周期已复核。

### Implementation Tasks

- [x] 使用 FileManager 的 Application Support API 解析 sandbox-safe 根目录。
- [x] 创建并验证 `library.json` 与 `storageLayoutVersion` 基线。
- [x] 实现仅允许批准顶级目录、规范 UUID 和文件种类的资源 ID factory。
- [x] 拒绝绝对路径、`..`、符号链接逃逸、控制字符和根目录外 URL。
- [x] 实现 staging write、内容校验 hook、原子 move 和失败清理。
- [x] 实现 JPEG/PNG/HEIC/HEIF 真实格式检测、导入上限与基础 thumbnail 生成；不可稳定构造的系统格式测试必须显式 skip。
- [x] 实现按明确资源 ID 的读取、存在性检查、容量统计和单文件删除。
- [x] 实现 owner 目录和 cache 命名规则，但不进行未经确认的批量永久删除。
- [x] 定义跨 Storage/Repository Service 的成功顺序与补偿行为。
- [x] 让测试可注入独立临时根目录，不读取真实用户资料库。

### Tests

- [x] 测试首次启动建目录与重复初始化幂等性。
- [x] 测试合法资源 ID 往返解析和非法路径拒绝。
- [x] 测试 staging 原子写入、失败补偿和同 owner 并发串行化。
- [x] 测试原始、processed、thumbnail 和 generation result 的位置规则。
- [x] 测试 JPEG/PNG 导入、thumbnail 尺寸/方向，以及 HEIC/HEIF 在系统 fixture 能力可用时的导入。
- [x] 测试重建 Service 后仍能通过同一相对资源 ID 读取 fixture。
- [x] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [x] 重启/重建 StorageService 后持久资源仍可访问。
- [x] 数据层只保存受控相对资源 ID，不依赖绝对路径。
- [x] 文件系统错误不会留下被数据库静默引用的半写入文件。
- [x] StorageService 有独立、无用户数据风险的测试覆盖。

### Documentation Updates

- [x] 实际 bundle container、目录布局和 storageLayoutVersion 已记录。
- [x] 若原子写入或补偿策略变化，更新 `docs/STORAGE_SPEC.md` 和 `docs/ARCHITECTURE.md`。
- [x] 在本 Stage 下记录测试命令和结果。

### Execution Record（2026-08-11）

- 生产根目录：通过 FileManager Application Support API 解析为 `<Application Support>/com.lishunjie.Wardrobe/Wardrobe/`；SwiftData store 位于受控 `database/WardrobeV1.store`。`storageLayoutVersion = 1`，`library.json` 初始化幂等。
- Storage：`StorageServing` 注入 `StorageService` actor；`StorageResourceID` 只接受批准顶级目录、小写规范 UUID 与固定文件名，并在 Codable decode 时再次验证。读写、exists、move、单文件/owner 目录删除、staging 临时文件、容量与基础 cache API 均由该 actor 管理。
- 图片导入：ImageIO 检测 JPEG/PNG/HEIC/HEIF 真实格式，不信任扩展名；限制 100 MiB 与 100,000,000 像素。原图保留，基础 thumbnail 为方向修正后的最大边 512 px、JPEG quality 0.82；processed 仅提供受控 placeholder reference，不实现 Stage 3 pipeline。
- 目录发布与补偿：新 owner 在 `staging/<operation UUID>/` 完成复制、复验和 thumbnail 后原子 rename；失败只清理明确 operation/owner。跨 Repository 操作使用 `StorageCompensationTransaction` 显式登记并逆序 rollback。
- Unit Tests：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage2FinalDerivedData -only-testing:WardrobeTests test` → `TEST SUCCEEDED`；24 个 Stage 2 tests 中 23 passed、1 skipped（当前 ImageIO runtime 无法编码 HEIF fixture），既有 9 个 Stage 1 tests 与 2 个 smoke tests 全部通过。HEIC fixture 实测通过。
- UI Tests：已执行独立 UI test 与全 scheme test；App 进程和主窗口正常创建，但当前 Codex 终端没有 macOS Accessibility/System Events 授权，XCUIApplication 无法把 `Running Background` App 激活并在 60 秒后失败。该环境限制已如实记录，未将其标记为通过；UI test 使用独立临时 Storage root，不接触正式目录。
- Debug Build：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage2FinalDerivedData build` → `BUILD SUCCEEDED`，无源码 warning/error；仅见 Xcode 对未链接 AppIntents 的 metadata extraction 工具提示。
- 安全审计：最终 Unit Test 后正式 Application Support 根未被重建；首次发现的空测试宿主资料库已整体移至废纸篓以便恢复。源码无 `/Users`、Desktop 或 Documents 路径，`WardrobeSchemaV1` 未新增或保存图片 Data/absolute path。

### Completion Checklist

- [x] Storage 安全测试与 build 通过。
- [x] 已证明不存在路径逃逸和绝对路径持久化。
- [x] 人工检查真实 Application Support 目录结构后再继续高层导入功能。

---

## Stage 3：图片处理流水线

### Goal

在本地建立确定性、可取消、可测试的图片标准化与缩略图流水线，为衣物和人物功能提供稳定输入。

### Scope

- [x] 图像解码、UTType/MIME 校验和 EXIF 方向规范化。
- [x] 像素尺寸限制、缩放、色彩空间统一和压缩。
- [x] JPEG thumbnail 生成与 PNG processed image 生成。
- [x] 处理配置和算法版本化。
- [x] 背景去除扩展协议预留，默认使用 no-op/未启用实现。
- [x] 图片处理错误、取消和内存压力处理。

### Out of Scope

- [x] 不调用第三方云图片 API。
- [x] 不实现自动标签、颜色识别或 AI 抠图。
- [x] 不在 SwiftUI View 中直接使用处理 API。

### Dependencies

- [x] Stage 2 已通过。
- [x] 目标输入/输出格式与最大尺寸已经从 Storage 与 AI 文档确认。

### Implementation Tasks

- [x] 定义 `ImageProcessingService` 协议、输入、输出和稳定错误类型。
- [x] 实现方向修正、尺寸计算、缩放和色彩空间标准化。
- [x] 实现 thumbnail 与 processed 输出参数，避免重复解码同一源图。
- [x] 实现超大图降采样，避免先完整展开造成峰值内存失控。
- [x] 将处理产物通过 StorageService 写入，不直接拼路径。
- [x] 为处理配置加入版本号，旧历史引用的派生资源不可静默覆盖。
- [x] 加入 Task cancellation 检查和临时文件清理。
- [x] 定义可选 BackgroundRemovalService 协议，但不提供云实现。

### Tests

- [x] 使用不同 EXIF 方向、尺寸、格式和色彩空间 fixture 测试。
- [x] 测试 thumbnail 像素边、宽高比、格式和可解码性。
- [x] 测试损坏文件、伪造扩展名、超大图和不支持格式。
- [x] 测试取消后不提交产物且 staging 被清理。
- [x] 测试相同输入和配置生成稳定规格的输出。
- [x] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [x] 原图保持不变，processed 与 thumbnail 可可靠生成和读取。
- [x] 方向、尺寸和压缩规则符合 `STORAGE_SPEC.md`。
- [x] 错误可被 Service/UI 映射，且不会留下半成品元数据。
- [x] 无真实云 API 依赖。

### Documentation Updates

- [x] 在 `docs/STORAGE_SPEC.md` 记录实际格式、尺寸、质量和处理版本。
- [x] 在 `docs/ARCHITECTURE.md` 记录处理服务边界与并发策略。
- [x] 在本 Stage 下记录 fixture 和测试结果。

### Execution Record（2026-08-11）

- Abstraction：新增 `ImageProcessingServing`/`ImageProcessingService`、显式 `ImageProcessingPreset`/`ImageProcessingOptions`、稳定 `ImageProcessingError` 与 async `BackgroundRemovalProviding`；composition root 注入生产 service。图片层不依赖 SwiftUI、SwiftData Repository、AI Provider 或衣服 CRUD。
- Preset/输出：`garment` 为最长边 2048 px、保留 alpha、thumbnail 512 px / JPEG 0.82；`person` 为最长边 4096 px、白底去 alpha、thumbnail 512 px / JPEG 0.86；预留 `generatedResult` 为 3072 px / JPEG 0.84。全部保持宽高比、不裁剪，processed 为 orientation up 的 8-bit sRGB PNG。
- Version/metadata：pipeline version 为 `wardrobe-image-v1`，写入结果 metadata 和 PNG `Software` 字段；来源 EXIF/定位/相机/色彩 metadata 不复制。固定 `processed.png` 已存在时拒绝覆盖，未来重处理由生命周期 Service 先做引用预检并采用受控版本资源策略；未修改冻结的 `WardrobeSchemaV1`。
- Storage/原子性：新增窄接口 `ImageProcessingStorageServing`。Storage 从 original 创建受控 staging workspace，验证 processed PNG/thumbnail JPEG 后在 actor 内发布；若替换 Stage 2 thumbnail 失败则恢复旧文件。取消/失败清理明确 operation，不向图片服务或 View 暴露通用删除能力，original bytes 在测试中保持不变。
- Memory/Concurrency：在 bitmap 创建前复用 100 MiB、100,000,000 pixel 和真实格式校验；ImageIO source cache 关闭，`CGImageSourceCreateThumbnailAtIndex` 直接做 orientation transform 与目标尺寸降采样。处理在 detached worker 上执行，并在校验、降采样、背景 provider、颜色转换、编码与发布前检查 cancellation；取消保持 `CancellationError` 语义。
- Background removal：`DisabledBackgroundRemovalProvider` 是 deterministic no-op，无 Vision 私有/高版本 API、第三方 SDK、网络或真实 AI 调用；协议可由未来 Apple Vision、AI 与 Mock provider 替换。
- Fixtures/Unit Tests：新增 14 个 Stage 3 tests，覆盖 rotated JPEG、透明 PNG、HEIC、processed/thumbnail 解码、preset 尺寸/宽高比、sRGB/alpha/version、Stage 2 thumbnail 协作、15MP 降采样、超过 100M pixel 的低内存 PNG fixture、非图片、取消、失败/取消无半成品、不可覆盖与 service/storage 重建读取。
- 全部 Unit Tests：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage3FinalDerivedData -only-testing:WardrobeTests test` → `TEST SUCCEEDED`；49 total，48 passed、1 skipped、0 failed。skip 为 Stage 2 已记录的 HEIF encoder 条件限制；Stage 3 HEIC fixture 实测通过。
- UI Tests：同一 project/scheme/destination/DerivedData，`-only-testing:WardrobeUITests test` → `TEST SUCCEEDED`；1 个 launch/sidebar smoke test passed。UI test 注入独立临时 Storage root。
- Debug Build：同一 project/scheme/destination/DerivedData 执行 `build` → `BUILD SUCCEEDED`，无源码 warning/error；测试构建仅见既有 Xcode AppIntents metadata extraction 提示。
- 安全审计：正式 Application Support 根在本轮测试前已存在（文件时间 14:49，测试从 14:54 后执行），最终 garments/persons/generations/staging 均无子项且时间未被本轮测试更新；Stage 3 tests/UITests 使用 `/tmp` 隔离 root。源码未新增网络调用、衣服 CRUD、永久删除路径、Schema V2 或 Stage 4 功能。

### Completion Checklist

- [x] 图片 fixture 测试、内存基本检查和 build 通过。
- [x] processed/thumbnail 生成责任只存在于 ImageProcessingService。
- [x] 未引入云依赖或业务 UI。

---

## Stage 4：衣橱管理

### Goal

完成衣物从导入到浏览、编辑、归档和检索的本地核心闭环。

### Scope

- [x] 衣橱自适应 Grid、详情和添加/编辑表单。
- [x] 衣物图片导入、元数据保存、收藏、归档、恢复和永久删除流程。
- [x] 搜索、分类/收藏/属性筛选和排序。
- [x] ViewModel、Repository 和 Import/Deletion Service 编排。

### Out of Scope

- [x] 不实现人物、AI 生成、穿搭保存或批量导入。
- [x] 不实现自动标签、自动抠图或高级全文检索。
- [x] 不让 View 直接使用 ModelContext、Storage 或图片处理器。

### Dependencies

- [x] Stage 1–3 已通过。

### Implementation Tasks

- [x] 实现 Wardrobe Repository 查询条件、分页/批次策略和稳定排序。
- [x] 实现 `ImportClothingService`：验证→Storage→ImageProcessing→Repository→补偿。
- [x] 实现 @MainActor ViewModel/State，区分 loading、empty、filtered-empty、content 和 error。
- [x] 实现符合 `UI_SPEC.md` 的 LazyVGrid、Toolbar、Inspector/detail 与系统文件导入。
- [x] 实现全部 ClothingItem 元数据编辑和输入规范化。
- [x] 实现收藏、软归档、归档区恢复和永久删除影响预检。
- [x] 实现搜索防抖、组合筛选、最近添加/修改/名称/收藏排序。
- [x] 实现图片缺失/损坏占位和可操作错误，不在 View 拼路径。

### Tests

- [x] 测试 ClothingItem 创建、读取、编辑、收藏、归档、恢复和永久删除。
- [x] 测试导入各步骤失败时数据库/文件补偿一致。
- [x] 测试搜索、组合筛选、排序和未知 code 展示。
- [x] 测试永久删除保留被 Outfit/Generation 快照引用的资源策略。
- [x] UI 测试添加衣物→重启 App→再次打开衣物详情。
- [x] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [x] 完整衣物 CRUD、收藏、归档、搜索、筛选和排序可用。
- [x] 导入后重启 App 图片和元数据仍可访问。
- [x] 普通删除默认归档，永久删除有明确影响说明和确认。
- [x] UI 无数据库、图片处理或文件系统业务逻辑。

### Documentation Updates

- [x] 实际搜索字段、筛选组合和永久删除行为已与 `PRODUCT_SPEC.md`/`UI_SPEC.md` 一致。
- [x] 新增 Service 或 Repository 边界时更新 `ARCHITECTURE.md`。
- [x] 在本 Stage 下记录 build/test 与人工流程结果。

### Execution Record（2026-08-11）

- Feature 架构：新增 `ClothingQuery`/`ClothingDraft`/`ClothingRecord` 展示与输入模型，`WardrobeViewModel` 只持有 Stage 4 use cases 和只读图片加载器。UI 使用原生 toolbar、search、filter/sort menu、adaptive LazyVGrid、详情栏、sheet、系统文件选择器与 destructive confirmation；不引用 ModelContext、Storage 路径或图片处理器。
- Import：`ImportClothingService` 先规范化全部 metadata 并生成稳定 Clothing UUID，再执行 Storage staging import、ImageProcessing garment pipeline、ClothingItem 构造与 Repository save。数据库提交前失败会清理本次明确 owner 目录；主错误与 cleanup issue 分离，取消保持 CancellationError；提交后不再执行可能删除已发布文件的补偿步骤。
- Delete/retention：`ResourceReferenceInspector` 覆盖 Clothing、Person、Outfit、OutfitItem、GenerationRecord、GenerationPersonInput 与 GenerationGarmentInput 的全部资源字段。`ClothingDeletionService` 在 metadata/nullify 保存后检查 surviving references；任一资源仍被引用则保留完整 owner 目录，全部无引用才执行目录清理；cleanup failure 不回滚数据库。
- Query：搜索名称、品牌、颜色、材质、普通标签，250 ms 防抖；组合筛选分类、季节、风格、颜色、收藏和 active/archived/all；排序为最近添加、最近修改、名称、收藏优先，UUID 提供稳定 tie-breaker，单次批次上限 250。
- Grid：只按 processed→thumbnail→placeholder 加载，不在 Grid 解码 original；资源缺失或损坏显示统一占位。编辑 metadata 不重新导入或处理图片，Stage 4 不开放图片替换。
- App 边界：`AppEnvironment` 只向 Wardrobe Feature 注入 `WardrobeFeatureDependencies`；完整 `StorageServing`/`ImageProcessingServing` 留在 composition root。导入、目录清理和只读加载分别通过窄能力协议使用，Feature 无法直接调用 destructive Storage API。
- Stage 4 Unit Tests：新增 14 个测试，覆盖 JPEG/PNG/HEIC、metadata、重建 container/storage、edit/favorite/archive/restore、搜索筛选排序、Storage/Processing/Repository failure rollback、无引用删除、Outfit/Generation snapshot retention、unrelated resource、cleanup failure 与全字段 ResourceReferenceInspector。
- 全量 Unit Tests：`xcodebuild -project Wardrobe.xcodeproj -scheme Wardrobe -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/WardrobeStage4FinalDerivedData -only-testing:WardrobeTests test` → `TEST SUCCEEDED`；63 total，62 passed、1 skipped、0 failed。skip 仍为既有 HEIF encoder 条件限制；Stage 4 HEIC fixture 实测通过。
- UI Tests：同一 project/scheme/destination/DerivedData，`-only-testing:WardrobeUITests test` → `TEST SUCCEEDED`；2 passed。保留五项 Sidebar navigation smoke，并新增隔离 fixture 流程：衣物详情→收藏→编辑→关闭/重启 App（不重复注入）→重新打开持久化详情→归档。
- Debug Build：同一 project/scheme/destination/DerivedData 执行 `build` → `BUILD SUCCEEDED`；无源码 warning/error，测试构建仅见 Xcode 对未链接 AppIntents 的 metadata extraction 提示。
- 数据安全：Unit Tests 使用 in-memory/persistent temporary container 与临时 Storage；UI Tests 使用 `WARDROBE_STORAGE_ROOT_OVERRIDE` 隔离根。正式 Application Support 的 manifest/database 文件时间仍停留在 14:49–14:50，garments/persons/generations/outfits/staging 均无子项，本阶段测试未污染正式资料库。源码未加入真实网络、AI Provider、Schema V2 或 Stage 5 功能。

### Completion Checklist

- [x] 衣物端到端流程和错误路径均通过。
- [x] 无硬编码绝对路径或图片 Data 入库。
- [x] 人工验收衣橱 CRUD 和永久删除提示后再进入依赖衣橱的 Stage。

---

## Stage 5：人物照片管理

### Goal

稳定管理 AI 试穿所需的人物档案、多张全身参考照和默认选择。

### Scope

- [x] 人物列表、人物详情、创建/编辑/归档。
- [x] 每个人物添加多张参考照、设置默认人物和主参考照。
- [x] 删除人物图片与永久删除人物的引用影响处理。
- [x] 人物图片导入、processed/thumbnail 和缺失资源状态。

### Out of Scope

- [x] 不调用 AI、不评价人物照片质量或自动选最佳照片。
- [x] 不实现云同步或人脸识别。
- [x] 不让 View 直接操作 Storage 或 SwiftData。

### Dependencies

- [x] Stage 1–3 已通过。
- [x] Stage 4 的通用导入/删除交互模式可复用，但不得形成 Feature 间反向依赖。

### Implementation Tasks

- [x] 实现 Person Repository 与 ImportPersonImage/Deletion Service。
- [x] 实现人物列表、详情和参考照缩略图 Grid。
- [x] 实现默认人物与每个人物主参考照的独立命令。
- [x] 在 Service 层保证至多一个活跃默认人物和每档案至多一张主图。
- [x] 删除主图后按既定规则选择新主图或清空，并通知 UI。
- [x] 归档人物后从试衣选择器默认排除，但保留历史可追溯性。
- [x] 永久删除前检查 Generation input 引用，保留仍被快照引用的资源。

### Tests

- [x] 测试人物 CRUD、归档和多图关系。
- [x] 测试并发/连续设置默认人物与主图的唯一性。
- [x] 测试删除主图、最后一张图片和被历史引用图片。
- [x] 测试图片导入失败补偿和重启读取。
- [x] UI 测试使用隔离的多图人物 fixture→设置默认人物→编辑→重启读取；系统文件面板与图片导入/主图切换由 Service tests 覆盖。
- [x] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [x] 可以稳定创建人物并管理多张参考照。
- [x] 默认人物和主图语义明确且约束不依赖 UI。
- [x] 被生成历史引用的资源不会因源人物删除而丢失。
- [x] 图片不进入 SwiftData，路径不写死。

### Documentation Updates

- [x] 若默认选择或删除策略变化，更新 `DATA_MODEL.md`、`PRODUCT_SPEC.md` 和 `UI_SPEC.md`。
- [x] 在本 Stage 下记录测试与人工验证结果。

### Execution Record（2026-08-11）

- Feature/架构：新增“我的形象”Sidebar route、人物列表 + 详情双栏、adaptive reference thumbnail Grid、processed 大图预览、创建/编辑/归档/恢复、Default/Primary 独立命令与危险删除确认。`PersonViewModel` 只持有四个专用用例和只读图片加载器，不接触 ModelContext、Storage 路径或图片处理器。
- Import：`ImportPersonImageService` 为每张图片生成稳定 UUID，并以 `persons/<PersonImage UUID>/` 独立 owner 执行 Storage staging import、Stage 3 `.person` preset（4096 px processed、512 px thumbnail）、SwiftData 保存和失败补偿；original 不被覆盖。主错误与 cleanup issue 分离，取消保持 `CancellationError`。
- Invariants/reference：Repository 在 MainActor 上保证最多一个 active default 与每档案最多一张 primary。归档默认人物后 default 置空；第一张图自动为 primary；删除 primary 后按 createdAt、UUID 选择最早剩余图。`PersonReferenceSet` 稳定提供 Default Profile → Primary → Additional images，未创建 Schema V2。
- Delete/retention：单图删除与档案 cascade 删除都在 metadata 提交前收集完整资源，提交 nullify/cascade 后复用全模型 `ResourceReferenceInspector`。每个 PersonImage owner 独立判断：任一资源仍被 Generation snapshot 引用则保留完整 owner，否则删除目录；cleanup failure 不回滚数据库。
- Stage 5 Unit Tests：新增 14 个，覆盖 CRUD/归档、Default/Primary 唯一性、多图、JPEG/PNG/HEIC、person preset 与尺寸、Storage/Processing/Repository failure、主图 fallback、单图/档案删除、snapshot retention、cleanup failure 和持久 container/storage 重建。
- 全量 Unit Tests：`xcodebuild ... -collect-test-diagnostics never -only-testing:WardrobeTests test` → `TEST SUCCEEDED`；77 total，76 passed、1 skipped、0 failed。skip 为既有 Stage 2 HEIF encoder 条件限制；Stage 5 HEIC 实测通过。
- UI Tests：`xcodebuild ... -collect-test-diagnostics never -only-testing:WardrobeUITests test` → `TEST SUCCEEDED`；3 个测试在同一完整 suite 中全部通过，覆盖六项 Sidebar navigation、既有 Stage 4 clothing 持久化流程、人物隔离多图 fixture 的 default/编辑/重启读取。Sidebar smoke 改用已解析元素的中心坐标点击，规避 XCTest 在全套顺序下错误地对数值 accessibility value 做 regex matching；每例 teardown 显式终止 App。系统文件面板不做脆弱自动化，测试使用 `WARDROBE_STORAGE_ROOT_OVERRIDE`，未访问正式资料库。
- Debug Build：`xcodebuild ... -derivedDataPath /tmp/WardrobeStage5DevDerivedData build` → `BUILD SUCCEEDED`；无源码 warning/error，仅见既有 AppIntents metadata extraction 提示。Xcode 自动序列化的无语义 `Wardrobe.xcscheme` 差异已移除。
- 环境记录：UI diagnostics 曾因磁盘空间不足写入失败；只删除了两个明确的大型临时诊断文件，随后以 `-collect-test-diagnostics never` 重跑。该问题不涉及项目或正式资料库内容。
- 安全审计：Person Feature 未获得 destructive Storage API；源码无网络/真实 AI、OpenAI、Schema V2 或 Stage 6 实现；正式 Application Support 未产生测试 Person/Image。

### Completion Checklist

- [x] 人物素材完整流程通过。
- [x] 关系/资源生命周期测试通过。
- [x] 人工确认默认人物、主图和删除行为后再进入真实生成链路。

---

## Stage 6：AI Provider 基础架构

### Goal

建立供应商中立、可替换、可测试的虚拟试穿协议和 Mock Provider，为 UI 与未来真实 Provider 提供稳定边界。

### Scope

- [x] `VirtualTryOnProvider`、`VirtualTryOnCapabilities` 和 Provider registry。
- [x] `VirtualTryOnRequest`、`ProviderImage`、`TryOnGarment`、`TryOnOptions`、`VirtualTryOnResult`。
- [x] `VirtualTryOnError`、能力校验、Prompt Builder 边界。
- [x] `MockVirtualTryOnProvider` 的成功、失败、延迟和取消模式。

### Out of Scope

- [x] 不调用 OpenAI 或任何真实/付费 API。
- [x] 不创建完整 GenerationRecord 编排；属于 Stage 10。
- [x] 不把供应商 SDK 类型放入 Domain 或 UI。

### Dependencies

- [x] Stage 0–1 已通过。
- [x] `docs/AI_ARCHITECTURE.md` 的协议、错误和能力模型已复核。

### Implementation Tasks

- [x] 定义小而稳定、`Sendable` 的 Provider 协议与中立数据结构。
- [x] 定义人物图片数量、槽位、格式、大小、质量和取消能力。
- [x] 定义 TryOnOptions 的 schemaVersion 与 providerParameters allowlist 边界。
- [x] 定义稳定 Provider ID，展示名与持久 ID 分离。
- [x] 实现 ProviderRegistry，由 composition root 注册，不使用全局可变单例。
- [x] 实现 Mock Provider 固定结果、延迟、瞬时失败、永久失败与取消。
- [x] 实现 Provider contract test suite，供未来所有 Adapter 复用。
- [x] 确认日志不输出图片 Data、完整 Prompt 或敏感配置。

### Tests

- [x] 测试 Request Codable/Sendable 设计所需行为和 options 版本化。
- [x] 测试能力不支持、多图超限、槽位超限和非法输入。
- [x] 测试 Mock 成功、失败、延迟、Task cancellation 和迟到结果。
- [x] 测试 Registry 选择、缺失 Provider 和重复 ID。
- [x] 运行 build 和全部现有 tests，确认无网络访问。

### Acceptance Criteria

- [x] UI/Domain 可只依赖 Provider 中立类型。
- [x] Mock Provider 可完整驱动后续试衣 UI 和测试。
- [x] 新 Provider 可通过 Adapter 与 Registry 加入，不修改 Feature。
- [x] 自动测试不会调用真实 API。

### Documentation Updates

- [x] 实际协议和 capability 字段同步到 `AI_ARCHITECTURE.md`。
- [x] 若依赖方向变化，更新 `ARCHITECTURE.md`。
- [x] 在本 Stage 下记录 contract tests 结果。

### Execution Record（2026-08-11）

- Provider API：新增 `ProviderID`/`ProviderDescriptor`、`VirtualTryOnProvider`、`VirtualTryOnCapabilities`、`VirtualTryOnRequest`、`ProviderImage`、`TryOnGarment`、版本化 `TryOnOptions`/`JSONValue`、`VirtualTryOnResult` 与稳定 `VirtualTryOnError`。值类型均为 Provider 中立的 `Sendable`；请求编码不包含 Storage resource ID、URL 或绝对路径。
- Validation/Prompt：`VirtualTryOnRequestValidator` 先验证 Provider capability 定义，再验证人物/衣物图片、重复 ID、MIME、字节/像素、人物数量、槽位/逐槽位及总数限制、质量、宽高比、seed、Prompt 长度、options schemaVersion 与 provider parameter allowlist。`TryOnPromptBuilder` 使用语义槽位和稳定排序，模板版本为 `wardrobe-try-on-prompt-v1`。
- Registry/Composition：`ProviderRegistry` 为 actor，初始化时拒绝非法/重复稳定 ID，缺失选择返回稳定错误；由 `AppEnvironment` composition root 持有且只注册 `mock`，没有全局可变单例。
- Mock：`MockVirtualTryOnProvider` 为无文件/无网络 actor，固定返回 `wardrobe-mock-result-v1`；可注入 success、前 N 次 transient failure、permanent failure 与 Swift Concurrency delay。取消在延迟前后检查并规范化为 `.cancelled`，不会提交迟到结果。
- Stage 6 focused tests：`xcodebuild ... -collect-test-diagnostics never -only-testing:WardrobeTests/Stage6VirtualTryOnProviderTests test` → `TEST SUCCEEDED`；15 passed，覆盖 Codable/version、Prompt、contract、capability/非法输入、成功/两类失败/重试/延迟/取消/迟到结果与 Registry。
- 全量 Unit Tests：`xcodebuild ... -derivedDataPath /tmp/WardrobeStage6FinalDerivedData -collect-test-diagnostics never -only-testing:WardrobeTests test` → `TEST SUCCEEDED`；92 total，91 passed、1 skipped、0 failed。skip 为既有 HEIF encoder fixture 条件限制。
- UI Tests：同一 project/scheme/destination/DerivedData，`-only-testing:WardrobeUITests test` → `TEST SUCCEEDED`；3 passed，保留 Stage 0–5 的导航、衣橱和人物隔离流程。Stage 6 按范围不实现 Stage 7 Try-On UI，因此没有新增试衣 UI test。
- Debug Build：同一 project/scheme/destination/DerivedData 执行 `build` → `BUILD SUCCEEDED`；无源码 warning/error，仅 Unit test 构建出现既有 AppIntents metadata extraction 提示。Xcode 自动序列化的无语义 `Wardrobe.xcscheme` 差异已移除。
- 安全审计：AI 源码未导入网络框架、未出现 OpenAI/API Key/Authorization/URLSession、未访问 Storage 或 SwiftData，也未提供 destructive API。`WardrobeSchemaV1` 和 Stage 7 Try-On Feature 未修改；正式 Application Support 的 manifest/业务目录时间仍停留在本阶段测试前，未产生测试资产。

### Completion Checklist

- [x] Provider API review 与 contract tests 通过。
- [ ] 人工确认协议没有 OpenAI 特有语义泄漏后再实现 Try-On UI。

---

## Stage 7：AI 试衣间 UI

### Goal

使用 Mock Provider 建立原生 macOS 三栏试衣工作区，使用户能形成完整、有效的 Provider 中立请求。

### Scope

- [ ] 人物/参考照选择、人物画布、衣橱侧栏和当前搭配栏。
- [ ] 五类 `TryOnSlot`：Upper Body、Outerwear、Lower Body、Footwear、Accessories。
- [ ] Drag & Drop、替换、移除、Accessories 排序和键盘等价操作。
- [ ] TryOn ViewModel/State、类别/槽位校验和能力提示。
- [ ] 使用 Mock Provider 预览请求结果，不保存真实生成历史。

### Out of Scope

- [ ] 不调用真实 AI，不实现 OpenAI 请求。
- [ ] 不实现完整生成持久化、重试或历史页面。
- [ ] 不实现像素坐标式衣物摆放。

### Dependencies

- [ ] Stage 4–6 已通过。

### Implementation Tasks

- [ ] 实现符合 `UI_SPEC.md` 的三栏布局及窗口宽度适配。
- [ ] 实现稳定 ClothingItem ID 的 Transferable/drop payload，不传图片 Data。
- [ ] 实现单值槽位替换与 Accessories 多值排序。
- [ ] 实现类别建议、无可靠映射类别拒绝和 Provider capability 最终校验。
- [ ] 实现人物多参考照选择与 Provider maxPersonImages 提示，不静默丢弃。
- [ ] 实现 TryOn State 与 `VirtualTryOnRequestBuilder`，View 只发送用户意图。
- [ ] 为拖拽提供 context menu/键盘/VoiceOver 等价路径。
- [ ] 用 Mock Provider 展示准备、运行、成功、失败、取消状态样例。

### Tests

- [ ] 测试五类槽位添加、替换、移除、排序和请求映射。
- [ ] 测试不兼容类别、归档衣物、缺失图片和 capability 限制。
- [ ] 测试人物/主图默认选择与多图超限提示。
- [ ] UI 测试拖拽和非拖拽等价操作。
- [ ] 测试离开页面取消任务且不会重复提交。
- [ ] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [ ] 用户可从衣橱和人物素材形成完整有效的 Try-On Request。
- [ ] 拖拽改变语义槽位，不依赖人物图片像素位置。
- [ ] UI 不依赖具体 Provider 或 OpenAI 类型。
- [ ] 本 Stage 的所有生成行为由 Mock Provider 完成。

### Documentation Updates

- [ ] 实际槽位规则、窗口适配和无障碍替代操作同步到 `UI_SPEC.md`。
- [ ] 请求构造边界变化时更新 `AI_ARCHITECTURE.md`。
- [ ] 在本 Stage 下记录 UI 流程验收结果。

### Completion Checklist

- [ ] Mock 试衣流程与 UI tests 通过。
- [ ] 人工验收拖拽、键盘路径、槽位语义和 Mac 布局后继续。

---

## Stage 8：设置与安全

### Goal

在接入真实 Provider 前建立安全的凭据、Provider 选择和非敏感设置基础。

### Scope

- [ ] Provider 设置、默认质量/宽高比/通用参数。
- [ ] `CredentialStore` 协议与 macOS Keychain 实现。
- [ ] API Key 新增、替换、删除和配置状态显示。
- [ ] Storage 位置/容量信息与安全的 Cache 清理入口。
- [ ] Settings Repository 和原生 Settings scene/window。

### Out of Scope

- [ ] 不调用真实 Provider 验证付费请求。
- [ ] 不回显完整 API Key，不把密钥放入 UserDefaults/SwiftData。
- [ ] 不实现备份恢复或任意资料库根目录切换。

### Dependencies

- [ ] Stage 2 与 Stage 6 已通过。

### Implementation Tasks

- [ ] 定义 CredentialStore，Keychain service/account 使用稳定标识。
- [ ] 实现 Keychain 写入、读取存在状态、替换和删除，处理用户拒绝/锁定错误。
- [ ] 实现版本化非敏感 Settings 模型和 Repository。
- [ ] 实现 Provider 选择与 capability 驱动参数 UI，避免具体 Provider 条件散落。
- [ ] API Key UI 只显示已配置/未配置和掩码，不提供完整回读。
- [ ] 显示受控 Application Support 资料库位置、持久资源与 Cache 大小。
- [ ] Cache 清理只调用 StorageService 的受控 API，不影响持久资源。
- [ ] 确认日志、崩溃信息、备份入口和 UI state 不包含密钥。

### Tests

- [ ] 使用内存 CredentialStore 测试 ViewModel 与 Provider 配置流程。
- [ ] 在可控测试环境验证 Keychain add/update/delete 和错误映射。
- [ ] 测试设置版本解码、未知参数保留/忽略策略和默认值。
- [ ] 测试 Cache 清理不删除 garments/persons/generations。
- [ ] 运行源码/构建产物敏感字符串检查、build 和全部 tests。

### Acceptance Criteria

- [ ] API Key 只存在 Keychain，应用不回显完整值。
- [ ] 无 Key 时本地功能正常，生成入口给出可操作提示。
- [ ] Provider/质量设置通过抽象层影响请求，不渗透 View。
- [ ] Cache 清理安全且资料库路径只读展示。

### Documentation Updates

- [ ] 实际 Keychain 标识和设置字段以不含秘密的方式记录到 `AI_ARCHITECTURE.md`。
- [ ] 设置界面差异同步到 `UI_SPEC.md`。
- [ ] 在本 Stage 下记录安全检查与测试结果。

### Completion Checklist

- [ ] Security review、Keychain tests 和 build 通过。
- [ ] 人工确认密钥生命周期和 Cache 清理范围后，才能接入真实 Provider。

---

## Stage 9：OpenAI Provider

### Goal

在不污染 Domain/UI 的前提下实现可选 OpenAI Adapter；只有官方 API 在实现时确实支持所需输入与输出时才启用。

### Scope

- [ ] 实现时核对最新官方 OpenAI 文档、模型能力、限制、费用和数据处理规则。
- [ ] OpenAI 网络层、请求构造、图片输入、Prompt 映射、响应解析和错误映射。
- [ ] Retry、Cancel、超时和 Provider contract tests。
- [ ] 从 CredentialStore 按需读取 API Key。

### Out of Scope

- [ ] 不把 OpenAI SDK/HTTP 类型暴露到 Domain、ViewModel 或 View。
- [ ] 不在自动测试中发起真实付费请求。
- [ ] 不在官方能力不匹配时伪造“虚拟试穿”支持或加入不可维护 workaround。

### Dependencies

- [ ] Stage 3、6、8 已通过。
- [ ] 实现当天已查阅 OpenAI 官方文档并记录日期、模型/API 与能力结论。
- [ ] 已确认 OpenAI API 能合法、稳定地处理 V1 人物/衣物参考输入；否则本 Stage 标记 blocked 并评估 SpecializedVTONProvider。

### Implementation Tasks

- [ ] 仅使用官方 OpenAI 文档确认当前请求方式，不依赖过期示例或记忆。
- [ ] 建立独立 OpenAI DTO/Adapter，将中立 request 映射到官方 API。
- [ ] 通过 CredentialStore 提供短生命周期凭据，不缓存/记录明文 Key。
- [ ] 实现图片格式、大小、数量和模型 capability 的预校验。
- [ ] 实现 Prompt Adapter，同时保留 Provider 中立 Prompt 版本。
- [ ] 实现响应图片/错误解析、providerRequestID 和 providerModelID 映射。
- [ ] 将 OpenAI 错误规范化为 `VirtualTryOnError`，对日志脱敏。
- [ ] 实现 timeout、Task cancellation、迟到响应丢弃和受限 Retry。
- [ ] 明确幂等性与重复计费风险；无保证时禁止盲目自动重试。

### Tests

- [ ] 使用 URLProtocol/网络 mock 测试请求字段、图片编码和响应解析。
- [ ] 覆盖鉴权、限流、网络中断、拒绝、无效响应、超时和取消。
- [ ] 运行通用 Provider contract tests。
- [ ] 静态检查 OpenAI 类型未出现在 Domain/Features 公共接口。
- [ ] 可选人工 smoke test 必须显式确认费用、使用测试素材并记录结果；不作为自动测试。
- [ ] 运行 build 和全部非付费 tests。

### Acceptance Criteria

- [ ] OpenAI Adapter 可由 Registry 选择，移除后不影响其他 Provider 或 UI。
- [ ] API Key 不进入源码、日志、SwiftData、UserDefaults 或备份。
- [ ] Retry/Cancel/Error 行为符合 `AI_ARCHITECTURE.md`。
- [ ] 官方能力不满足时，本 Stage 不以 hack 强行通过。

### Documentation Updates

- [ ] 在 `AI_ARCHITECTURE.md` 记录已确认的官方能力、限制和 Adapter 差异。
- [ ] 记录官方文档链接、核对日期和人工测试费用说明。
- [ ] 若无法支持 V1，记录 blocker 和替代 Provider 决策，不修改核心协议迎合单一供应商。

### Completion Checklist

- [ ] Contract/security tests 与 build 通过。
- [ ] 人工完成隐私、费用、模型能力和错误行为评审后才可进入完整生成链路。

---

## Stage 10：AI 生成流程

### Goal

实现人物、衣物、选项、Provider、GenerationRecord 和结果文件之间可靠、可取消、可恢复的完整编排。

### Scope

- [ ] `VirtualTryOnService` 与生成状态机。
- [ ] 输入快照、Provider 调用、结果 Storage 写入和 GenerationRecord 更新。
- [ ] Loading、Failure、Cancel、受限 Retry 与 Regenerate。
- [ ] Mock Provider 完整链路；OpenAI Provider 为可选人工路径。

### Out of Scope

- [ ] 不实现穿搭保存和完整历史浏览页面。
- [ ] 不覆盖旧 GenerationRecord；重新生成必须创建新记录。
- [ ] 不做后台并发队列或无限自动重试。

### Dependencies

- [ ] Stage 2–3、5–9 已通过；若 Stage 9 blocked，Mock Provider 链路仍可推进，但不能宣称真实 AI 可用。

### Implementation Tasks

- [ ] 在任何图片读取/网络调用前创建 queued GenerationRecord 与人物/衣物输入快照。
- [ ] 实现 queued→preparing→running→succeeded/failed 和任意非终态→cancelled。
- [ ] 通过 Storage 解析输入并构造 ProviderImage，不暴露永久路径给 Provider。
- [ ] 校验人物数量、槽位、格式、大小和 Provider capabilities。
- [ ] 成功结果先 staging 校验和原子写入，再提交 resultResourceID 与终态。
- [ ] 保存脱敏错误、attemptCount、时间、Provider/模型/request ID 和 options JSON。
- [ ] 实现瞬时错误受限 Retry；取消、鉴权、拒绝和输入错误不自动重试。
- [ ] 实现 Regenerate 新记录和 `sourceGenerationID` 链接。
- [ ] 实现启动恢复器处理异常退出遗留的非终态记录。

### Tests

- [ ] 测试成功状态和结果文件/元数据一致性。
- [ ] 测试准备、Provider、Storage、Repository 各阶段失败。
- [ ] 测试取消竞态、迟到结果、Retry 次数和不重复计费策略。
- [ ] 测试 Regenerate 不修改来源记录且输入快照正确。
- [ ] 测试异常退出遗留记录恢复策略。
- [ ] UI 测试 Mock 生成 Loading→Success/Failure/Cancel。
- [ ] 运行 build 和全部非付费 tests。

### Acceptance Criteria

- [ ] Mock Provider 可完成输入→记录→结果落盘→展示全链路。
- [ ] 每个生成尝试都有可诊断历史，失败/取消不丢记录。
- [ ] 数据库与文件不会因部分失败静默不一致。
- [ ] Regenerate 创建新记录，旧结果不可变。

### Documentation Updates

- [ ] 实际状态机、恢复策略和补偿顺序同步到 `AI_ARCHITECTURE.md`/`ARCHITECTURE.md`。
- [ ] Generation 字段变化同步到 `DATA_MODEL.md`。
- [ ] 在本 Stage 下记录端到端测试结果。

### Completion Checklist

- [ ] 状态机、竞态和补偿测试通过。
- [ ] 人工验收取消、失败、重新生成和结果持久化后再实现历史 UI。

---

## Stage 11：穿搭管理

### Goal

让用户保存、维护和重新载入由 Try-On Slot 组成的衣服组合。

### Scope

- [ ] 保存当前搭配为 Outfit/OutfitItem。
- [ ] 穿搭列表、详情、收藏、名称/备注编辑、归档和永久删除。
- [ ] 从穿搭载入试衣间并处理归档/缺失衣物。

### Out of Scope

- [ ] 不实现穿着记录、自动封面排版、版本历史或分享。
- [ ] 不静默替换已删除或不兼容衣物。

### Dependencies

- [ ] Stage 4 与 Stage 7 已通过。

### Implementation Tasks

- [ ] 实现 Outfit Repository 和 Outfit Service。
- [ ] 保存时验证至少一个有效 Item、单值槽位唯一和 Accessories 顺序。
- [ ] 保存 clothingItemID、名称和 thumbnail resource 快照。
- [ ] 实现列表/详情、搜索、收藏、编辑、归档与删除。
- [ ] 载入试衣间时识别活跃、归档、关系 nullify 和槽位不兼容项。
- [ ] 对缺失项显示快照占位并要求用户明确处理。
- [ ] 确保 Outfit 永久删除只 cascade OutfitItem，不删除 ClothingItem 或源图片。

### Tests

- [ ] 测试保存、读取、编辑、收藏、归档和删除。
- [ ] 测试槽位唯一性、Accessories 顺序和空穿搭拒绝。
- [ ] 测试源衣物归档/永久删除后的快照与载入提示。
- [ ] UI 测试当前搭配→保存→关闭/重启→载入试衣间。
- [ ] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [ ] 当前搭配可以稳定保存和重新载入。
- [ ] 删除穿搭不影响衣物，删除衣物不误删穿搭。
- [ ] 缺失/归档衣物不被静默替换。

### Documentation Updates

- [ ] 实际穿搭行为与 `PRODUCT_SPEC.md`、`DATA_MODEL.md`、`UI_SPEC.md` 一致。
- [ ] 在本 Stage 下记录测试结果。

### Completion Checklist

- [ ] Outfit 关系/删除测试与 UI 流程通过。
- [ ] 没有提前实现 Future 穿着统计或分享能力。

---

## Stage 12：生成历史

### Goal

提供成功、失败和取消记录的可靠浏览、诊断、重新生成和删除能力。

### Scope

- [ ] Generation History 列表、筛选和详情。
- [ ] 展示结果、输入人物、所用衣物/槽位、Provider、时间、状态、Prompt/参数和脱敏错误。
- [ ] 从历史重新生成、保存穿搭和删除记录/专属结果。

### Out of Scope

- [ ] 不实现云同步、成本统计或批量任务队列。
- [ ] 不显示 API Key、Authorization 信息或原始供应商敏感响应。

### Dependencies

- [ ] Stage 5 与 Stage 10 已通过。
- [ ] Stage 11 已通过时启用“保存为穿搭”；否则该动作保持不可用且不加临时实现。

### Implementation Tasks

- [ ] 实现 Generation Repository 的倒序、状态和 Provider 筛选查询。
- [ ] 实现列表缩略图/状态占位和完整详情。
- [ ] 使用快照字段展示已删除源人物/衣物，不依赖当前关系存在。
- [ ] 实现 Regenerate 载入和新记录创建入口。
- [ ] 实现成功记录保存为 Outfit 的映射。
- [ ] 实现删除影响摘要：删除 GenerationRecord、输入子项和专属结果，不影响源素材。
- [ ] 删除共享引用资源前进行全局 resource ID 引用检查。

### Tests

- [ ] 测试成功、失败、取消和中断记录查询与展示映射。
- [ ] 测试源对象删除后历史快照仍可读。
- [ ] 测试 Regenerate 链和保存 Outfit。
- [ ] 测试删除历史仅删除专属且无其他引用的资源。
- [ ] UI 测试筛选、详情、重新生成和危险删除确认。
- [ ] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [ ] 所有终态记录均可查看并解释。
- [ ] 源素材删除不破坏历史事实。
- [ ] 重新生成不覆盖旧结果。
- [ ] 删除历史不会误删衣物、人物或共享资源。

### Documentation Updates

- [ ] 删除语义和历史展示差异同步到 `PRODUCT_SPEC.md`、`STORAGE_SPEC.md` 和 `UI_SPEC.md`。
- [ ] 在本 Stage 下记录资源引用测试结果。

### Completion Checklist

- [ ] 历史快照、重新生成和删除 tests 通过。
- [ ] 人工确认删除影响摘要与失败详情脱敏后继续。

---

## Stage 13：Schema Migration 加固

### Goal

在备份格式和 Release 冻结前，建立正式、可重复验证的数据与存储版本迁移机制。

### Scope

- [ ] `VersionedSchema`、`SchemaMigrationPlan` 和逐版本 fixture 测试体系。
- [ ] schemaVersion 与 storageLayoutVersion 的独立版本策略。
- [ ] 轻量/自定义迁移、失败回滚和升级后一致性检查。
- [ ] 已发布 Schema 不可变规则的工程化约束。

### Out of Scope

- [ ] 不为了演示迁移而无业务理由修改 V1 模型。
- [ ] 不删除旧 fixture 或直接编辑已发布 Schema 类型。
- [ ] 不在主线程执行长时间存储迁移。

### Dependencies

- [ ] Stage 1 已建立 V1 基线。
- [ ] V1 模型已完成跨功能验证并准备冻结。

### Implementation Tasks

- [ ] 固化 V1 Schema fixture、逻辑记录样本和资源 ID fixture。
- [ ] 建立迁移测试 harness，能从每个历史版本升级到当前版本。
- [ ] 定义新增字段、枚举 code、关系变化和多阶段回填规范。
- [ ] 实现升级后默认人物、主图、关系、状态和资源 ID 一致性检查。
- [ ] 建立 migration preflight、失败错误和不开放半迁移资料库的流程。
- [ ] 为 storage layout 迁移定义检查点、可恢复中断和版本提交顺序。
- [ ] 在代码评审规则中禁止修改已发布 VersionedSchema。

### Tests

- [ ] 测试 V1 fixture 打开与当前版本无损读取。
- [ ] 使用测试专用演进 Schema 验证轻量和自定义迁移 harness，不污染产品 Schema。
- [ ] 测试未知枚举 code、可选字段、关系 nullify/cascade 和时间默认值。
- [ ] 测试迁移中断/失败后原资料库仍可打开或可回滚。
- [ ] 测试 schemaVersion 与 storageLayoutVersion 不同步时的阻断。
- [ ] 运行 build 和全部 tests。

### Acceptance Criteria

- [ ] 首个 Release 的 V1 Schema 已冻结并有 fixture。
- [ ] 未来变更有明确 Migration Plan 和回归测试入口。
- [ ] 迁移失败不会静默破坏或开放半迁移资料库。
- [ ] 资源 ID 在迁移后保持有效或经过显式 Storage Migration 更新。

### Documentation Updates

- [ ] 实际版本、迁移流程和 fixture 维护规则同步到 `DATA_MODEL.md`/`STORAGE_SPEC.md`。
- [ ] 在本 Stage 下记录迁移测试矩阵。

### Completion Checklist

- [ ] Migration harness、fixtures、失败回滚测试通过。
- [ ] 人工 Schema review 并冻结当前发布模型后，才能进入备份恢复最终实现。

---

## Stage 14：备份与恢复

### Goal

实现不依赖绝对路径、可校验、可迁移、失败可回滚的完整用户资料库备份与替换恢复。

### Scope

- [ ] 版本化 `.wardrobebackup` 包、manifest、逻辑 metadata 导出、assets 和 checksums。
- [ ] Garments、Persons、Generations、Outfits 与必要元数据/资源。
- [ ] 备份预检、导出、验证、恢复预览、替换恢复和回滚快照。
- [ ] 恢复后数据/文件一致性检查。

### Out of Scope

- [ ] V1 不实现合并恢复、增量备份、定时备份、云备份或备份加密。
- [ ] 不复制运行中的 SwiftData SQLite 文件作为正式格式。
- [ ] 不备份 API Key、Keychain、日志、staging 或可重建 Cache。

### Dependencies

- [ ] Stage 2、12–13 已通过。

### Implementation Tasks

- [ ] 定义 backup format version、manifest Codable schema 和 checksums 算法。
- [ ] 以稳定 UUID、关系和 resource ID 逻辑导出全部记录。
- [ ] 收集被元数据引用的持久 assets，保留相对布局并检测缺失/孤儿。
- [ ] 在 staging 创建备份，完成校验后原子发布到明确目标。
- [ ] 恢复前校验路径、格式版本、校验和、空间、UUID 和关系冲突。
- [ ] 将旧逻辑记录通过 Migration 层转换到当前 Schema。
- [ ] 创建当前资料库可回滚快照，在隔离根完成导入验证后受控切换。
- [ ] 恢复失败自动回滚；成功后运行一致性检查并生成摘要。
- [ ] UI 明确 V1 是替换恢复，并在执行前要求人工确认。

### Tests

- [ ] 测试完整资料库 backup→清空测试容器→restore→逐记录/资源比较。
- [ ] 测试损坏 manifest、checksum、路径逃逸、缺文件、空间不足和不支持版本。
- [ ] 测试恢复中断和失败回滚，不留下半恢复状态。
- [ ] 测试 Keychain、cache、staging 和日志未进入备份。
- [ ] 测试资料库根路径变化后相对 resource ID 仍可解析。
- [ ] 运行 build 和全部 tests。

### Acceptance Criteria

- [ ] 完整用户数据可在不同绝对根路径下恢复。
- [ ] 备份具有格式版本、Schema/storage 版本和完整性校验。
- [ ] 失败恢复可回滚，原资料库保持可用。
- [ ] 敏感凭据和可重建 Cache 不进入备份。

### Documentation Updates

- [ ] 最终备份格式和恢复限制同步到 `STORAGE_SPEC.md`/`PRODUCT_SPEC.md`/`UI_SPEC.md`。
- [ ] 记录兼容矩阵、恢复风险和人工操作说明。
- [ ] 在本 Stage 下记录 round-trip 测试结果。

### Completion Checklist

- [ ] 备份 round-trip、损坏输入和回滚 tests 通过。
- [ ] 人工在隔离测试资料库完成备份/恢复验收后继续；不得直接用唯一真实资料库首次验证。

---

## Stage 15：UI / UX 打磨

### Goal

统一并完善原生 macOS 交互、状态反馈、无障碍和窗口适配，不重写已稳定业务层。

### Scope

- [ ] Empty、Loading、Filtered Empty、Error、Offline/Provider unavailable 状态。
- [ ] Toolbar、菜单、快捷键、Context Menu、Hover、焦点和危险操作确认。
- [ ] Drag & Drop feedback、键盘替代路径、VoiceOver 和减少动态效果。
- [ ] 窗口尺寸、Sidebar、Inspector、三栏折叠和多窗口基本行为。

### Out of Scope

- [ ] 不为了视觉效果重写 Repository、Service 或 Schema。
- [ ] 不引入网页 Dashboard 风格、过量卡片或动画。
- [ ] 不强行移植移动端导航模式。

### Dependencies

- [ ] Stage 4–5、7–8、11–12、14 已通过。

### Implementation Tasks

- [ ] 逐 Feature 对照 `UI_SPEC.md` 建立状态矩阵。
- [ ] 统一 Toolbar、菜单命令、快捷键和 selection 行为。
- [ ] 为删除、恢复、取消和覆盖等高风险操作统一确认文案。
- [ ] 完善 hover/drop target/focus/keyboard feedback，不以动画掩盖状态。
- [ ] 检查窄/宽窗口、Sidebar 隐藏和 Inspector 展开布局。
- [ ] 增加 VoiceOver label、阅读顺序、键盘可达性、对比度和减少动态效果支持。
- [ ] 使用统一图片占位、错误提示和 Quick Look/Finder 入口。
- [ ] 仅在 Feature 展示层做局部重构，保持已测试业务接口稳定。

### Tests

- [ ] UI tests 覆盖主导航、空态、错误态、Toolbar 和 context menu。
- [ ] 测试拖拽与键盘等价流程。
- [ ] 使用不同窗口尺寸、浅/深色、减少动态效果进行人工检查。
- [ ] 使用 Accessibility Inspector/VoiceOver 检查关键流程。
- [ ] 运行 build 和全部现有 tests。

### Acceptance Criteria

- [ ] 核心流程符合 macOS 习惯且无需依赖精确拖拽。
- [ ] 所有页面明确呈现加载、空、错误和不可用状态。
- [ ] 关键操作可由键盘和 VoiceOver 完成。
- [ ] 无大规模业务层重写或无意义视觉复杂度。

### Documentation Updates

- [ ] 实际交互差异同步到 `UI_SPEC.md`。
- [ ] 新快捷键、菜单和已知无障碍限制记录到 README/Known Issues 草稿。
- [ ] 在本 Stage 下记录人工 UI 检查矩阵。

### Completion Checklist

- [ ] UI tests、无障碍检查和 build 通过。
- [ ] 业务层测试保持通过，确认没有因打磨破坏稳定模块。

---

## Stage 16：性能与可靠性

### Goal

验证真实个人资料库规模下的内存、查询、图片、异步任务、Cache 和文件一致性，并修复已测量瓶颈。

### Scope

- [ ] 大量衣物/人物/历史记录下的 SwiftData 查询和 Grid 性能。
- [ ] Thumbnail 使用、图片解码/释放、内存峰值和任务取消。
- [ ] Cache 容量、staging 恢复、文件一致性和 orphan report/cleanup。
- [ ] AI 请求、恢复和长任务生命周期可靠性。

### Out of Scope

- [ ] 不凭猜测进行大规模优化或架构重写。
- [ ] 不自动永久删除未经确认的孤儿文件。
- [ ] 不用降低图片/数据正确性换取不可测量的性能收益。

### Dependencies

- [ ] Stage 10、14–15 已通过。

### Implementation Tasks

- [ ] 定义代表性数据规模、图片尺寸、机器环境和性能预算。
- [ ] 创建不含私人素材的可重复性能 fixture。
- [ ] 使用 Instruments 测量启动、Grid 滚动、搜索、图片导入、生成准备和历史加载。
- [ ] 确认列表只加载 thumbnail，原图/processed 按需加载并及时释放。
- [ ] 检查 async Task 所有权、页面离开取消、actor contention 和迟到结果。
- [ ] 为高频 SwiftData 查询建立合理 predicate/sort/fetch limit，基于测量决定是否索引/分页。
- [ ] 实现 Cache 上限与安全清理策略。
- [ ] 实现只读 orphan 扫描报告；自动清理必须有引用检查、宽限期和明确范围。
- [ ] 实现启动时过期 staging 与中断 generation 的受控恢复。

### Tests

- [ ] 运行大数据 fixture 的性能基线和回归测量。
- [ ] 运行内存峰值、重复打开详情和快速滚动检查。
- [ ] 测试取消、并发导入、应用重启和磁盘不足。
- [ ] 测试 orphan report 区分缺失文件与无引用文件，且默认不删除。
- [ ] 测试 Cache 清理和 staging 恢复不影响持久资源。
- [ ] 运行 build 和全部 tests。

### Acceptance Criteria

- [ ] 达到已记录的可接受启动、滚动、搜索和导入预算。
- [ ] 大图处理和列表浏览无持续内存增长或明显泄漏。
- [ ] 取消与页面生命周期不会产生重复写入或悬空任务。
- [ ] 文件一致性问题可报告，清理不会误删历史引用资源。

### Documentation Updates

- [ ] 记录性能基线、测试机器、数据规模和优化原因。
- [ ] Cache/orphan 策略变化同步到 `STORAGE_SPEC.md`。
- [ ] 在本 Stage 下记录 Instruments 结果摘要。

### Completion Checklist

- [ ] 关键性能预算与可靠性测试通过。
- [ ] 人工审查 orphan cleanup 和所有自动删除边界后继续。

---

## Stage 17：完整测试

### Goal

以发布候选配置验证所有层和关键用户闭环，确认无真实 API 依赖的自动测试可稳定重复运行。

### Scope

- [ ] Unit、Repository、Storage、ImageProcessing、Migration、Backup、AI Mock 与关键 UI Flow Tests。
- [ ] 完整闭环：添加衣物→选择人物→拖入衣物→生成→保存→重新打开。
- [ ] 删除、失败、取消、重启、恢复和升级等高风险路径。

### Out of Scope

- [ ] 不用真实付费 AI API 作为自动验收依赖。
- [ ] 不为通过测试删除断言、fixture 或错误处理。
- [ ] 不在测试阶段加入未规划功能。

### Dependencies

- [ ] Stage 0–16 全部通过。

### Implementation Tasks

- [ ] 建立测试覆盖矩阵，将每个 V1 PRODUCT_SPEC 能力映射到测试。
- [ ] 补齐 Service 状态机、Repository 关系、Storage 路径和图片错误测试。
- [ ] 补齐 Migration fixtures 与 Backup round-trip 组合测试。
- [ ] 补齐 Mock Provider 成功、失败、限流模拟、取消、迟到结果和 Regenerate。
- [ ] 建立关键 UI Flow 的稳定 fixture、accessibility identifier 和隔离资料库。
- [ ] 运行 fresh install、existing data、restored data 三种启动场景。
- [ ] 运行 Debug 与 Release 配置测试，记录 flaky test 并修复根因。

### Tests

- [ ] 全部 Unit Tests 通过。
- [ ] 全部 Repository/SwiftData Tests 通过。
- [ ] 全部 Storage/ImageProcessing Tests 通过。
- [ ] 全部 Migration/Backup Tests 通过。
- [ ] 全部 AI Mock/Service Tests 通过。
- [ ] 关键 UI Flow Tests 通过。
- [ ] Release build 通过且自动测试无外网/付费调用。

### Acceptance Criteria

- [ ] V1 核心闭环在全新与重启场景均通过。
- [ ] 高风险删除、迁移、恢复、Keychain 和生成状态有明确测试证据。
- [ ] 无已知阻塞级失败或未解释 flaky test。
- [ ] 测试不包含真实密钥或私人图片。

### Documentation Updates

- [ ] 测试矩阵、运行命令、环境和已知限制写入测试文档/README。
- [ ] 发现规格冲突时先修正对应 docs，再修测试或实现。
- [ ] 在本 Stage 下记录最终测试报告摘要。

### Completion Checklist

- [ ] 完整自动测试和 Release build 通过。
- [ ] 人工执行一次核心闭环并核对持久化结果。
- [ ] 人工 Go/No-Go 后才能进入 Release 准备。

---

## Stage 18：Release 准备

### Goal

将通过完整测试的构建整理为可长期自用、可升级、可诊断的首个 Release。

### Scope

- [ ] Release Build、签名/权限、App metadata、App Icon 占位或正式资源。
- [ ] 日志、Debug code、API Key、数据目录和备份恢复最终检查。
- [ ] README、架构文档、Known Issues、版本与升级说明。
- [ ] Release 候选人工验收和可回滚发布资料。

### Out of Scope

- [ ] 不加入未完成的新功能或临时 Release hack。
- [ ] 不在最后阶段无故重写稳定模块。
- [ ] 不宣称未验证的真实 Provider 能力可用。

### Dependencies

- [ ] Stage 17 已通过并完成 Go/No-Go。

### Implementation Tasks

- [ ] 设置版本号、build number、最低 macOS 版本、bundle metadata 和权限说明。
- [ ] 生成/检查 App Icon、应用名称、菜单、About 信息和隐私描述。
- [ ] 运行 Release archive/build，检查签名、sandbox entitlement 和网络/文件权限最小化。
- [ ] 搜索并清理临时 debug UI、测试入口、示例密钥、敏感日志和无用 feature flag。
- [ ] 检查 Application Support、Keychain、Cache、staging 和 backup 路径。
- [ ] 用 Release candidate 执行 fresh install、升级 fixture、备份恢复和核心闭环。
- [ ] 完成 README：安装、资料库位置、备份、Provider 配置、故障恢复和测试说明。
- [ ] 完成 Architecture documentation、Known Issues 和版本发布记录。
- [ ] 保留发布前资料库备份和可回滚的上一构建（首发则记录恢复方案）。

### Tests

- [ ] Release Build/Archive 成功。
- [ ] Release 配置完整测试通过。
- [ ] API Key/敏感信息静态扫描通过。
- [ ] 签名、sandbox、首次启动、升级、恢复和核心 UI smoke test 通过。
- [ ] 在无 API Key、无网络和 Mock Provider 环境验证本地功能。

### Acceptance Criteria

- [ ] Release 可安装、启动、保存数据、重启、升级和恢复。
- [ ] 无明文 API Key、敏感日志、Debug 后门或绝对路径依赖。
- [ ] README、架构、数据、存储、AI、UI 和 Known Issues 与实现一致。
- [ ] 所有未完成项被明确列入 Known Issues/Future，不伪装完成。

### Documentation Updates

- [ ] 更新 README、版本记录、Known Issues 和全部发生偏差的设计文档。
- [ ] 记录 Release build/test 命令、环境、产物和备份位置。
- [ ] 将本清单对应 Stage 标记和验收证据更新完整。

### Completion Checklist

- [ ] Release checklist 全部完成。
- [ ] 人工完成最终安全、数据恢复和核心流程验收。
- [ ] 建立下一版本 Schema/功能变更前的文档与 Migration 流程。

---

## 阶段顺序调整记录

原始需求包含 Stage 0–18，共 19 个阶段；本清单保留相同数量和全部功能范围，但按依赖重新编号：

1. **图片处理流水线提前**：原 Stage 5 调整为 Stage 3，位于衣橱和人物 UI 之前。衣物/人物导入都依赖方向修正、缩略图和 processed 输出；先做 UI 再补流水线会制造重复实现或临时 hack。
2. **衣橱与人物顺延**：原 Stage 3/4 调整为 Stage 4/5，以 Storage 和 ImageProcessing 的稳定接口为基础。
3. **Provider 基础架构提前**：原 Stage 7 调整为 Stage 6，位于试衣间 UI 之前。试衣 UI 需要中立 Request、capabilities 和 Mock Provider，不能先依赖尚未定义的抽象。
4. **试衣间 UI 顺延**：原 Stage 6 调整为 Stage 7，且仅由 Mock Provider 驱动。
5. **设置与安全提前**：原 Stage 12 调整为 Stage 8。OpenAI Provider 在读取 API Key 前必须先有 CredentialStore/Keychain 和安全边界；不能在 Provider 内临时保存密钥。
6. **OpenAI 与完整生成链顺延**：原 Stage 8/9 调整为 Stage 9/10，以 Provider、Keychain、Storage 和图片处理为前置。
7. **穿搭与生成历史顺延**：原 Stage 10/11 调整为 Stage 11/12，与完整生成流程保持顺序一致。
8. **Schema Migration 提前于备份恢复**：原 Stage 14 调整为 Stage 13，原 Stage 13 调整为 Stage 14。备份 manifest 和恢复流程依赖正式 schemaVersion、storageLayoutVersion 与迁移 harness。
9. **VersionedSchema 基线不延后**：尽管 Migration 加固位于 Stage 13，`WardrobeSchemaV1` 和空的/基线 `SchemaMigrationPlan` 必须在 Stage 1 创建，避免先发布无版本数据库再补迁移。

## 高风险与人工 Gate 原则

- **最高风险**：Stage 1（关系和删除规则）、Stage 9（官方 AI 能力/费用/隐私）、Stage 10（跨数据库/文件/网络一致性）、Stage 13（Schema Migration）、Stage 14（备份恢复）、Stage 16（孤儿清理）、Stage 18（安全与发布）。
- **必须人工验收后继续**：Stage 0、1、2、4、5、6、7、8、9、10、12、13、14、16、17、18。
- 人工 Gate 关注实际数据安全、危险删除、API 费用/隐私、迁移回滚和备份恢复；通过自动测试不能替代这些确认。
