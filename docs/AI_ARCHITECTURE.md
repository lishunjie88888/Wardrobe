# AI 虚拟试穿架构

## 1. 目标

AI 虚拟试穿是可选能力，必须通过 Provider 抽象接入。应用的衣橱、人物、穿搭和历史领域模型不依赖 OpenAI 或任何特定供应商；切换 Provider 不应要求修改 SwiftUI View 或迁移核心业务数据。

本文只定义边界和数据流，不接入真实 API。

## 2. 模块边界

```text
TryOn View
    ↓ user intent
TryOnViewModel
    ↓ provider-neutral request
VirtualTryOnService
    ├── GenerationRepository
    ├── StorageService / ImageProcessingService
    ├── CredentialStore (Keychain)
    └── VirtualTryOnProvider
            └── concrete provider adapter
```

- View 只编辑人物选择、Try-On Slot、Prompt 和通用选项。
- Service 创建历史、准备输入、控制重试/取消、保存结果和更新状态。
- Provider 只执行一次供应商调用并返回 Provider 中立结果。
- Provider 不访问 SwiftData，不展示 UI，不决定文件永久存储位置。

## 3. Provider 协议草案

以下代码仅是接口设计示例，不是 API 实现：

```swift
protocol VirtualTryOnProvider: Sendable {
    var id: String { get }
    var capabilities: VirtualTryOnCapabilities { get }

    func validateConfiguration() async throws
    func generate(
        request: VirtualTryOnRequest
    ) async throws -> VirtualTryOnResult
}
```

协议保持小而稳定。进度流、任务查询或服务端取消只有在多个 Provider 都有明确需要时再通过独立可选协议扩展，避免把某家供应商语义写入基础接口。

## 4. Provider 中立类型

```swift
struct VirtualTryOnRequest: Sendable {
    let requestID: UUID
    let personImages: [ProviderImage]
    let garments: [TryOnGarment]
    let prompt: String
    let options: TryOnOptions
}

struct ProviderImage: Sendable {
    let id: UUID
    let data: Data
    let mediaType: String
}

struct TryOnGarment: Sendable {
    let clothingItemID: UUID
    let slot: TryOnSlot
    let image: ProviderImage
    let displayName: String
}

struct TryOnOptions: Codable, Sendable {
    let schemaVersion: Int
    let quality: OutputQuality
    let aspectRatio: AspectRatio
    let seed: Int?
    let providerParameters: [String: JSONValue]
}

struct VirtualTryOnResult: Sendable {
    let imageData: Data
    let mediaType: String
    let providerRequestID: String?
    let providerModelID: String?
    let revisedPrompt: String?
    let metadata: [String: String]
}
```

- `ProviderImage` 由 Service 通过 Storage 读取并校验后创建，不向 Provider 暴露永久文件路径。
- `personImages` 允许多张参考图；Provider 的 `capabilities.maxPersonImages` 决定实际支持数量。Service 不得静默丢弃多余图片。
- `garments` 使用语义 `TryOnSlot`；Provider Adapter 负责映射到供应商字段。
- `providerParameters` 必须有 allowlist、可序列化并随 GenerationRecord 快照保存；禁止存入密钥。
- 大图片导致内存压力时，可在不改变业务边界的前提下引入受控流式 payload 或安全临时文件类型。

## 5. 能力协商

`VirtualTryOnCapabilities` 至少描述：

- 支持的人物参考图数量与输入格式。
- 支持的 Try-On Slot、每槽位最大衣物数和总衣物数。
- 支持的输出质量、尺寸、宽高比与透明度。
- 是否支持 seed、负向 Prompt、服务端取消和幂等 request ID。
- 文件大小与像素限制。

UI 根据能力禁用不支持选项，并说明原因；最终校验仍必须由 Service 和 Provider 执行，不能只依赖 UI。

## 6. Prompt 设计

- UI 可提供用户补充 Prompt，但最终 Prompt 由独立 `TryOnPromptBuilder` 依据人物、槽位和通用选项生成。
- Prompt Builder 输出 Provider 中立语义；具体 Provider Adapter 可追加供应商格式要求，但应将最终发送版本或可诊断摘要写入 GenerationRecord。
- Prompt 模板具有版本号，便于重现旧记录与分析结果差异。
- 日志默认不记录完整 Prompt；历史记录可保存 Prompt，但设置与隐私说明需明确其用途。

## 7. 凭据与 Provider 配置

- `CredentialStore` 协议提供按 Provider ID 读取、写入和删除凭据的能力，生产实现使用 macOS Keychain。
- Keychain item 的 service 使用稳定 bundle 标识，account 使用 Provider ID；API Key 不进入 SwiftData、UserDefaults、备份、崩溃日志或 GenerationRecord。
- 非敏感配置可通过 Settings Repository 保存，例如默认 Provider ID、质量和模型 ID。
- Provider 只在请求时获取短生命周期凭据；错误信息必须脱敏，不能包含 Authorization header 或完整密钥。

## 8. 生成状态与持久化

`VirtualTryOnService` 负责以下状态机：

```text
queued → preparing → running → succeeded
                           ↘ failed
```

任何非终态都可因用户或系统取消转入 `cancelled`。

1. 在读取图片或调用网络前创建 `GenerationRecord` 和输入快照。
2. 准备输入时记录 `preparing`；开始 Provider 调用时记录 `running`。
3. 成功结果经 Storage 原子写入后，保存结果资源 ID 并标记 `succeeded`。
4. 失败保存规范化错误并标记 `failed`；取消标记 `cancelled`，不伪装成失败。
5. 应用异常退出后，启动恢复器将长时间停留在非终态且无活跃任务的记录标记为可解释的中断失败，或提示用户重新生成。

## 9. Error、Retry 与 Cancel

建议规范化错误：

```swift
enum VirtualTryOnError: Error, Sendable {
    case invalidInput(reason: String)
    case unsupportedCapability(reason: String)
    case missingCredential(providerID: String)
    case authenticationFailed
    case rateLimited(retryAfter: Duration?)
    case networkUnavailable
    case providerUnavailable
    case rejected(reason: String?)
    case invalidResponse
    case storageFailure
    case cancelled
    case unknown
}
```

- Provider Adapter 将供应商错误映射为上述错误，保留脱敏诊断上下文。
- 自动 Retry 由 Service 策略控制，仅针对明确瞬时错误，并使用指数退避、抖动和最大次数。
- 鉴权失败、输入无效、内容拒绝和用户取消不自动重试。
- 如果 Provider 支持幂等 key，使用 GenerationRecord UUID；否则自动重试必须谨慎，避免重复计费。
- 取消通过 Swift Task cancellation 传播。Provider 应调用 `Task.checkCancellation()` 并取消底层请求；服务端无法取消时，也不得把迟到结果写入已取消记录。
- 用户“重新生成”始终创建新 GenerationRecord；自动 Retry 才增加同一记录的 `attemptCount`。

## 10. Provider 扩展

- `OpenAIProvider`：未来的 OpenAI Adapter，仅在该模块内部依赖 OpenAI 请求/响应。
- `SpecializedVTONProvider`：面向专用虚拟试衣后端，可声明更细的槽位能力。
- `LocalProvider`：本地模型或本机服务，不应要求 Feature 改写流程。
- `MockProvider`：测试和 SwiftUI Preview 使用，可模拟延迟、失败、取消与固定图片结果。

Provider 注册由 App composition root 中的 `ProviderRegistry` 完成。持久化只保存稳定 Provider ID；Provider 不可用时，历史仍可读取，设置页提示重新选择。

## 11. 测试与安全

- 自动测试默认只使用 MockProvider，禁止意外调用真实付费 API。
- Contract tests 对所有 Provider 验证输入校验、错误映射、取消、能力声明和结果解码。
- Service tests 覆盖状态转换、结果落盘失败、重试次数、取消竞态和重新生成链。
- 日志、测试 fixture 和截图不得包含真实 API Key 或私人人物照片。
- 真实 Provider 上线前单独完成隐私、费用、内容政策、超时和数据保留评审。
