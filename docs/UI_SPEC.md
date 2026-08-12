# macOS UI 规格

## 1. 设计目标

界面遵循原生 macOS 信息架构和交互习惯，优先使用 SwiftUI 系统组件、菜单、工具栏、侧边栏、Inspector、键盘操作和标准确认对话框。视觉服务于大量个人资产的高效浏览与编辑，不追求网页 Dashboard 风格。

## 2. 应用框架

主窗口使用 `NavigationSplitView`：

```text
Sidebar
├── 我的衣橱
├── AI 试衣间
├── 穿搭
├── 生成历史
└── 设置
```

- Sidebar 使用系统 selection 和 SF Symbols，支持显示/隐藏。
- 内容区根据 Feature 使用双栏或三栏布局；详情编辑优先使用 Inspector、sheet 或独立 detail，而非堆叠卡片。
- Toolbar 放置当前 Feature 的高频动作；低频动作进入菜单或 context menu。
- 支持常见键盘命令：新建、搜索、保存、删除/归档、刷新、打开设置；危险操作始终需要明确确认。
- 窗口恢复只保存非敏感 UI 状态，不保存 API Key 或图片数据。

## 3. 我的衣橱

### 3.1 布局

- 主内容使用自适应 `LazyVGrid` 展示衣物缩略图、名称、分类与收藏状态。
- 窗口较宽时使用可选 Inspector 显示所选衣物详情；窄窗口使用详情导航或 sheet。
- Toolbar 包含搜索、筛选、排序、添加衣物和视图选项。
- 空态提供“添加第一件衣服”，不显示无意义统计卡片。

### 3.2 搜索、筛选与排序

- 搜索覆盖名称、品牌、颜色、材质和普通标签；输入采用防抖，并由 ViewModel/Repository 构建查询。
- 筛选支持分类、季节、风格、收藏、归档状态等，可组合并清晰显示当前条件。
- 排序至少支持最近添加、最近修改、名称和收藏优先。
- 无结果时保留筛选条件并提供一键清除，不把“无结果”误显示为“衣橱为空”。
- Stage 4 实现的搜索字段为名称、品牌、颜色、材质和普通标签；采用 250 ms 防抖。筛选支持分类、季节、风格、颜色、收藏及 active/archived/all 归档状态；排序支持最近添加、最近修改、名称和收藏优先，并使用 UUID 作为相同排序值的稳定 tie-breaker。

### 3.3 操作

- 添加/编辑表单分组显示基本信息、分类属性、标签与图片。
- 图片导入使用系统文件选择器或拖入导入区；View 只产生导入意图，处理与保存由 Service 完成。
- 单击选择，双击打开详情；右键菜单提供编辑、收藏、归档和永久删除。
- 普通 Delete 默认归档；永久删除位于归档区或明确菜单，显示引用影响和不可逆提示。
- 异步导入显示局部进度和可理解错误，不冻结主窗口。
- Stage 4 Grid 只按 `processed → thumbnail → placeholder` 加载受控资源，不长期加载 original。添加表单覆盖全部 ClothingItem 手动元数据；编辑不提供图片替换入口，避免在尚无安全 replacement lifecycle 时伪装支持。
- 永久删除确认会显示 Outfit/Generation snapshot 数量；引用无法证明安全时保留文件。归档/恢复不触碰文件，默认衣橱仅显示 active 项，筛选菜单可进入归档区。

## 4. 人物照片管理

- 人物选择器显示档案名称、默认状态和主参考照。
- 详情中以缩略图网格展示多张全身照，支持添加、查看、设置主图和删除。
- 设置默认人物与设置主参考照是两个独立操作，菜单和标签不得混淆。
- 图片不满足格式、尺寸或方向要求时，在保存前给出具体提示；自动处理由 Image Processing Service 完成。
- 人物归档后默认不出现在试衣选择器，但生成历史仍显示其名称快照。
- Stage 5 在 Sidebar 增加“我的形象”，使用人物列表 + 详情的原生 Mac 双栏布局；列表只加载 primary thumbnail，详情以 adaptive thumbnail Grid 展示多张照片。
- 添加人物允许先只保存姓名与备注，并显示“尚未添加参考照片”；添加照片先展示本地预览，再呈现 importing/processing 状态并禁止重复提交。
- 点击缩略图按需加载 processed image 进行较大预览，不批量解码档案内的 4K 图片。Default Person 与 Primary Image 使用独立命令和标签。
- 归档默认人物后默认状态置空；删除主图后 UI 刷新为确定性选出的剩余最早图片。永久删除确认显示 Generation snapshot 影响，内部路径不进入用户错误信息。

## 5. AI 试衣间

### 5.1 三栏布局

```text
衣橱列表/筛选       人物与试衣画布       当前搭配/生成设置
```

- 左栏：紧凑衣物网格或列表，支持搜索、分类和收藏筛选，是拖拽源。
- 中栏：人物选择、参考照片选择、人物预览、生成状态与最终结果预览。
- 右栏：语义槽位、Prompt、通用质量选项、Provider 能力提示和生成按钮。
- 空间不足时左栏可折叠为 popover/侧栏，右栏可使用 Inspector；核心画布保持可用，不简单缩放移动端界面。

### 5.2 Try-On Slot

当前搭配包含：

- Upper Body
- Outerwear
- Lower Body
- Footwear
- Accessories

衣物拖入槽位时，drop target 读取稳定 ClothingItem ID 并由 ViewModel 校验类别与 Provider 能力。拖放修改 `TryOnSlot` 状态，不记录人物图片像素位置。

- 单值槽位已有衣物时，默认显示“替换”预览并在 drop 后替换。
- Accessories 支持多个，提供明确排序与移除操作。
- 不兼容槽位拒绝 drop 并解释原因；用户可通过显式操作覆盖建议规则，但 Provider 不支持时不能绕过。
- 键盘和 VoiceOver 用户可通过“添加到槽位”菜单完成与拖拽等价的操作。

### 5.3 生成交互

- 生成按钮仅在人物、至少一件衣物、Provider 配置和必需参数有效时启用；禁用时展示原因。
- 点击生成后显示准备和运行状态，并提供取消。切换页面不应意外重复提交。
- 成功后展示结果、保存穿搭、重新生成和在 Finder/Quick Look 中查看等合适操作。
- 失败显示脱敏错误、可行修复方式与重试/重新生成入口；失败记录仍进入历史。
- 重新生成创建新记录，可沿用并允许调整 Prompt/选项；旧结果不被覆盖。

Stage 7 实际工作区使用 macOS `HSplitView` 三栏：左栏为复用 Clothing query 的 active 衣橱浏览器（搜索、分类、收藏），中栏为 Person picker、aspect-fit 主图、reference selector 和 Mock 状态，右栏为五个 Slots 与生成操作。衣物卡使用稳定 UUID `Transferable`，可拖到兼容 Slot或中央画布自动路由；卡片“添加”按钮和 context menu 提供键盘/VoiceOver 等价路径。

单值槽位 drop 后直接替换，Accessories 允许多值、稳定排序与逐项移除；“清空”只清衣物并保留人物。人物切换保留衣物，取消当前生成并清除旧结果。界面区分 validating、generating、success、failure、cancelled；失败/取消可用当前 Session 重试，Mock success 明确说明不是真实 AI 图片。无人物、人物无主图、无衣物、筛选无结果、资源失效及 Provider 错误均有解释性状态。列表图片只用 processed→thumbnail，人物画布用 processed→original，Provider 输入用 processed→original。

Stage 8 的主按钮改为“使用 ChatGPT 生成”（推荐）；Debug 构建保留“Mock 测试生成”，Release 不展示不可工作的未来 Provider。准备完成 sheet 直接提供“打开 ChatGPT”“在 Finder 中显示素材”“再次复制 Prompt”“导入生成结果”“清理此临时素材”和“完成”，并显示人物/衣物数量及四步人工操作说明。系统 file importer 只接受可真实解码的图片；导入后中央区域显示并标记“ChatGPT 手动生成 · 已导入”。

Stage 10 将 Debug 的“Mock 测试生成”接入完整本地持久化编排：界面继续显示验证、生成、成功、失败和取消状态；成功时加载正式 Generation Storage 中的结果并说明输入快照已保存，失败/取消可用当前 Session 重试。Release 的推荐入口仍是 External ChatGPT，不展示或暗示真实付费 Provider。完整 Generation History 列表/详情仍属于 Stage 12。

稳定模式不会通过 Accessibility 控制 ChatGPT，也不会自动发送。所有新增按钮均有稳定 accessibility identifier；UI 测试可注入 clipboard/launcher/result fixture，运行时不打开真实 ChatGPT、不访问网络或控制其他 App。

## 6. 穿搭

- 使用网格或列表展示名称、衣物缩略图组合、收藏和修改时间。
- 支持搜索、收藏筛选、编辑、归档和载入试衣间。
- 穿搭详情按 Try-On Slot 分组展示 OutfitItem。
- 衣物已归档时显示状态但仍可查看；衣物被永久删除时显示快照占位，并在载入试衣间前要求用户处理缺失项。
- 保存当前搭配时允许输入名称、备注和收藏；V1 不要求复杂画布排版。

## 7. 生成历史

- 默认按创建时间倒序，支持状态和 Provider 筛选。
- 列表项显示结果缩略图或状态占位、人物名称快照、衣物摘要、Provider、时间与状态。
- 详情显示输入人物图片、各槽位衣物、Prompt、通用参数、Provider/模型、尝试次数、结果及脱敏错误。
- 对失败和取消记录也提供详情；成功记录支持重新生成和保存穿搭。
- 删除历史需说明是否同时删除生成结果。V1 建议提供“仅移除记录与其专属结果”的明确行为，源衣物和人物资源不受影响。

## 8. 设置

使用原生 Settings scene 或标准设置窗口，按以下分区：

- AI Provider：选择默认 Provider、显示能力、配置状态、模型与测试配置入口。
- 凭据：新增、替换或移除 API Key；完整密钥不回显，所有操作经过 Keychain Service。
- 生成：默认图片质量、宽高比和通用参数。
- 数据与存储：显示资料库位置、持久资源和 Cache 占用、清理 Cache。
- 备份与恢复：创建备份、查看最近结果、选择备份恢复并展示验证/影响摘要。

恢复属于高风险流程：必须显示格式版本、记录数、资源大小和将采用的恢复模式；执行前要求确认，并在完成后显示一致性检查结果。

## 9. 状态与反馈

- 每个 Feature 明确区分首次加载、内容、空态、筛选无结果、错误和离线/Provider 不可用状态。
- 可恢复的局部错误尽量就地显示；阻塞操作使用 sheet/alert；短暂成功提示可用非侵入式状态反馈。
- 长操作显示进度并允许合理取消；不使用无限动画掩盖未知状态。
- ViewModel 暴露展示状态，View 不从数据库或网络错误自行推导业务结论。

## 10. 原生 macOS 原则

- 优先标准控件、系统字体、动态颜色、SF Symbols、Toolbar、Menu、Inspector、Quick Look 与系统文件面板。
- 支持键盘导航、焦点环、右键菜单、多选语义、VoiceOver、减少动态效果和足够对比度。
- 动画只用于解释状态或空间变化，持续时间短且可被减少动态效果设置关闭。
- 避免网页 Dashboard 感、大面积统计卡片、无意义圆角容器、过度阴影和渐变。
- 避免把 iPhone 的底部 Tab、全屏推入导航、大触控按钮和单列卡片流直接移植到 Mac。
- 不将精确拖拽作为唯一交互路径，不要求用户命中人物图片上的像素位置。

## 11. UI 与架构边界

- View 不使用 `ModelContext`、Storage 路径、Keychain 或 Provider SDK。
- 拖放 payload 只包含稳定 ID 和必要的公开类型，不传整张图片二进制。
- 图片显示通过资源加载抽象获取；缺失和损坏资源有统一占位与修复入口。
- UI 中的 Provider 专属设置由 capability/schema 描述驱动，不能散落具体供应商条件判断。
- Preview 和 UI 测试使用内存 Repository、临时 Storage 和 MockProvider。
