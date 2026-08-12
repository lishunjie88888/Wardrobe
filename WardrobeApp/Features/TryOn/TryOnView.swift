import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClothingDragPayload: Codable, Transferable, Sendable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wardrobeClothing)
    }

    let clothingID: UUID
}

private extension UTType {
    static let wardrobeClothing = UTType(exportedAs: "com.lishunjie.Wardrobe.clothing")
}

struct TryOnView: View {
    @State private var model: TryOnViewModel
    @State private var showsExternalPackage = false
    @State private var importsExternalResult = false

    init(dependencies: TryOnFeatureDependencies) {
        _model = State(initialValue: TryOnViewModel(dependencies: dependencies))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clothingWidth = min(max(width * 0.28, 250), 360)
            let outfitWidth = min(max(width * 0.30, 290), 390)

            HStack(spacing: 0) {
                clothingBrowser
                    .frame(width: clothingWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                Divider()
                personCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                Divider()
                outfitPanel
                    .frame(width: outfitWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: width, height: geometry.size.height)
            .clipped()
        }
        .navigationTitle("AI 试衣间")
        .accessibilityIdentifier("tryon.feature")
        .task { model.load() }
        .onDisappear { model.cancelGeneration(setCancelledState: false) }
        .onChange(of: model.externalState) { _, state in
            switch state {
            case .ready, .imported: showsExternalPackage = true
            default: break
            }
        }
        .sheet(isPresented: $showsExternalPackage) { externalPackageSheet }
        .fileImporter(isPresented: $importsExternalResult, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importExternalResult(from: url) }
            else if case .failure = result { model.message = "无法读取所选图片，请重新选择。" }
        }
        .alert("试衣间提示", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) { Button("好") {} } message: { Text(model.message ?? "") }
    }

    private var clothingBrowser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择服饰")
                    .font(.headline)
                TextField("搜索衣物名称、品牌、标签…", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("tryon.clothing.search")
                    .onSubmit { model.filtersChanged() }
                HStack {
                    Picker("分类", selection: $model.categoryCode) {
                        Text("全部分类").tag(String?.none)
                        ForEach(ClothingCategory.allCases, id: \.rawValue) { Text($0.tryOnDisplayName).tag(Optional($0.rawValue)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Toggle(isOn: $model.favoritesOnly) {
                        Label("收藏", systemImage: model.favoritesOnly ? "star.fill" : "star")
                    }
                    .toggleStyle(.button)
                }
                .onChange(of: model.categoryCode) { _, _ in model.filtersChanged() }
                .onChange(of: model.favoritesOnly) { _, _ in model.filtersChanged() }
            }
            .padding(16)
            Divider()
            if model.clothing.isEmpty {
                ContentUnavailableView("没有可用衣物", systemImage: "tshirt", description: Text("请先在“我的衣橱”中添加或调整筛选。"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 12)], spacing: 14) {
                        ForEach(model.clothing) { item in
                            TryOnClothingCard(item: item, loader: model.imageLoader) { slot in
                                model.addClothing(item.id, to: slot)
                            }
                            .draggable(ClothingDragPayload(clothingID: item.id))
                            .accessibilityIdentifier("tryon.clothing.\(item.id.uuidString)")
                        }
                    }
                    .padding(14)
                }
                .safeAreaInset(edge: .bottom) {
                    Text("共 \(model.clothing.count) 件可用衣物")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
        .background(.background)
    }

    private var personCanvas: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.profiles.isEmpty {
                ContentUnavailableView("还没有人物资料", systemImage: "person.crop.rectangle", description: Text("请先在“我的形象”中添加人物参考照片。"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择人物")
                        .font(.headline)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(model.profiles) { profile in
                                Button {
                                    model.selectPerson(profile.id)
                                } label: {
                                    VStack(spacing: 5) {
                                        ZStack {
                                            TryOnAssetImage(
                                                resources: [profile.preferredThumbnailResourceID].compactMap { $0 },
                                                loader: model.imageLoader
                                            )
                                            .clipShape(Circle())
                                            Circle()
                                                .stroke(
                                                    profile.id == model.session.personProfileID ? Color.accentColor : Color.secondary.opacity(0.25),
                                                    lineWidth: profile.id == model.session.personProfileID ? 3 : 1
                                                )
                                        }
                                        .frame(width: 52, height: 52)
                                        Text(profile.draft.name)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("tryon.person.option.\(profile.id.uuidString)")
                            }
                        }
                    }
                    .accessibilityIdentifier("tryon.person.picker")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                if let profile = model.selectedProfile, let primary = model.currentReferences?.primaryImage {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.quaternary.opacity(0.2))
                        TryOnAssetImage(resources: [primary.processedResourceID, primary.originalResourceID].compactMap { $0 }, loader: model.imageLoader)
                            .padding(10)
                        HStack(spacing: 6) {
                            Text(profile.draft.name).font(.subheadline.bold())
                            if profile.isDefault {
                                Label("默认", systemImage: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("tryon.person.canvas")
                    .dropDestination(for: ClothingDragPayload.self) { payloads, _ in
                        payloads.reduce(false) { accepted, payload in model.addClothing(payload.clothingID) || accepted }
                    } isTargeted: { _ in }
                    .padding(.horizontal, 16)
                    referencePicker
                } else {
                    ContentUnavailableView("当前人物没有可用参考照片", systemImage: "photo.badge.exclamationmark", description: Text("请先为此人物添加并设置主参考照。"))
                }
                generationStatus
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder private var referencePicker: some View {
        if let references = model.currentReferences {
            let images = [references.primaryImage].compactMap { $0 } + references.additionalImages
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("人物参考照").font(.caption.bold())
                    Spacer()
                    Text("已选 \(model.session.selectedPersonImageIDs.count)/\(model.provider.capabilities.maxPersonImages)").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(images) { image in
                            Button {
                                model.toggleReference(image.id)
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    TryOnAssetImage(resources: [image.thumbnailResourceID, image.processedResourceID].compactMap { $0 }, loader: model.imageLoader)
                                        .frame(width: 58, height: 72)
                                    Image(systemName: model.session.selectedPersonImageIDs.contains(image.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.session.selectedPersonImageIDs.contains(image.id) ? Color.accentColor : .secondary)
                                        .padding(4)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(image.isPrimary ? "主参考照" : "附加参考照")
                            .accessibilityIdentifier("tryon.reference.\(image.id.uuidString)")
                        }
                    }
                }
                if model.omittedReferenceCount > 0 {
                    Text("另有 \(model.omittedReferenceCount) 张未自动选择，可取消当前图片后手动选择。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var generationStatus: some View {
        switch model.generationState {
        case .idle:
            Text("将衣物拖到右侧槽位或人物画布，形成当前搭配。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        case .validating:
            ProgressView("正在验证人物与衣物资源…")
        case .generating:
            HStack { ProgressView(); Text("Mock Provider 正在生成测试结果…") }
                .accessibilityIdentifier("tryon.generating")
        case let .success(preview):
            VStack(spacing: 6) {
                Label("Mock 试穿已完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                Text("这是 \(preview.providerName) 的测试结果，不是真实 AI 图片。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(preview.garmentsBySlot.flatMap(\.value).joined(separator: "、"))
                    .font(.caption).lineLimit(2)
            }
            .padding(10)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("tryon.mock.result")
        case let .failure(message):
            VStack { Label("Mock 生成失败", systemImage: "exclamationmark.triangle").foregroundStyle(.red); Text(message).font(.caption); Button("重试") { model.retry() }.accessibilityIdentifier("tryon.retry") }
        case .cancelled:
            VStack { Text("生成已取消").foregroundStyle(.secondary); Button("重试") { model.retry() }.accessibilityIdentifier("tryon.retry") }
        }
    }

    private var outfitPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("当前搭配").font(.headline)
                Spacer()
                Button { model.clearOutfit() } label: {
                    Label("清空搭配", systemImage: "trash")
                }
                    .disabled(model.session.garmentCount == 0)
                    .accessibilityIdentifier("tryon.clear")
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(TryOnSlot.allCases, id: \.self) { slot in
                        TryOnSlotView(slot: slot, model: model)
                    }

                    Text("生成方式")
                        .font(.headline)
                        .padding(.top, 4)

                    HStack(spacing: 10) {
                        generationMethodCard(
                            title: "使用 ChatGPT 生成",
                            subtitle: "准备素材后手动生成",
                            icon: "sparkles",
                            isSelected: true
                        )
#if DEBUG
                        Button { model.generate() } label: {
                            generationMethodCard(
                                title: "Mock 测试生成",
                                subtitle: "快速检查搭配流程",
                                icon: "cube",
                                isSelected: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canGenerate)
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .accessibilityIdentifier("tryon.generate")
#endif
                    }

                    Text("当前结果")
                        .font(.headline)

                    if let imported = model.importedResult {
                        VStack(spacing: 8) {
                            TryOnAssetImage(resources: [imported.resultResourceID], loader: model.imageLoader)
                                .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 220)
                            Label("ChatGPT 手动生成 · 已导入", systemImage: "square.and.arrow.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("tryon.external.imported-result")
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 30))
                            Text("生成结果将显示在这里")
                                .font(.subheadline)
                            Text("完成 ChatGPT 生成后导入图片")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 130)
                        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.separator, style: StrokeStyle(lineWidth: 1, dash: [5]))
                        }
                    }
                }
                .padding(14)
            }
            Divider()
            VStack(spacing: 10) {
                switch model.generationState {
                case .generating, .validating:
                    Button("取消生成", role: .cancel) { model.cancelGeneration() }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("tryon.cancel")
                default:
                    Button {
                        model.prepareExternalGeneration()
                    } label: {
                        Label("生成搭配", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.canGenerate)
                        .keyboardShortcut("g", modifiers: [.command])
                        .accessibilityIdentifier("tryon.external.generate")
                }
                if model.isPreparingExternal { ProgressView("正在准备本地素材…") }
                Text("Wardrobe 只准备本地素材，不上传图片、不调用 API")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
        }
        .background(.background)
    }

    private func generationMethodCard(title: String, subtitle: String, icon: String, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Spacer()
                if isSelected {
                    Text("推荐")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(title)
                .font(.caption.bold())
                .lineLimit(2)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 1.5 : 1)
        }
    }

    @ViewBuilder private var externalPackageSheet: some View {
        if let package = model.preparedPackage {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Label("AI 试衣素材已准备完成", systemImage: "checkmark.circle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                    Text("Prompt 已复制到剪贴板，参考图和衣物图已按上传顺序整理。")
                        .foregroundStyle(.secondary)
                    Text("请在 ChatGPT 中上传图片、粘贴 Prompt，并由你亲自确认发送。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if case .ready(let result) = model.externalState, !result.promptCopied {
                    Label("自动复制提示词失败，可从 prompt.txt 手动复制。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                GroupBox {
                    HStack {
                        packageSummaryItem(icon: "person.2", title: "人物参考图", value: "\(package.personAttachmentCount) 张")
                        Divider()
                        packageSummaryItem(icon: "tshirt", title: "衣物", value: "\(package.garmentAttachmentCount) 件")
                        Divider()
                        packageSummaryItem(icon: "photo", title: "参考图", value: "\(package.imageAttachments.count) 张")
                    }
                    .frame(maxWidth: .infinity)
                } label: {
                    Text("素材概览")
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(package.imageAttachments.enumerated()), id: \.element.id) { index, attachment in
                            VStack(spacing: 5) {
                                TryOnAssetImage(resources: [attachment.resourceID], loader: model.imageLoader)
                                    .frame(width: 92, height: 108)
                                Text("图 \(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                HStack(spacing: 12) {
                    GroupBox("已复制的 Prompt") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("可直接粘贴到 ChatGPT", systemImage: "doc.on.clipboard")
                                .font(.subheadline)
                            Button("再次复制 Prompt") { model.copyPreparedPrompt() }
                                .accessibilityIdentifier("tryon.external.copy-prompt")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("素材包内容") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("prompt.txt", systemImage: "doc.text")
                            Label("manifest.json", systemImage: "doc.badge.gearshape")
                            Text("共 \(package.imageAttachments.count + 2) 个文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Divider()
                HStack {
                    Button("打开 ChatGPT") { model.openChatGPT() }
                        .accessibilityIdentifier("tryon.external.open-chatgpt")
                    Button("在 Finder 中显示素材") { model.revealPreparedPackage() }
                        .accessibilityIdentifier("tryon.external.reveal")
                    Button("导入生成结果") {
                        if let injected = model.injectedResultURL { model.importExternalResult(from: injected) }
                        else { importsExternalResult = true }
                    }
                    .keyboardShortcut("i", modifiers: [.command])
                    .accessibilityIdentifier("tryon.external.import")
                    Spacer()
                    Menu {
                        Button("清理此临时素材", role: .destructive) {
                            model.cleanPreparedPackage()
                            showsExternalPackage = false
                        }
                        .accessibilityIdentifier("tryon.external.cleanup")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    Button("完成") { showsExternalPackage = false }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(26)
            .frame(width: 680)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tryon.external.ready-sheet")
        }
    }

    private func packageSummaryItem(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct TryOnClothingCard: View {
    let item: ClothingRecord
    let loader: any TryOnResourceLoading
    let add: (TryOnSlot?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TryOnAssetImage(resources: [item.processedResourceID, item.thumbnailResourceID].compactMap { $0 }, loader: loader)
                .frame(height: 120)
            Text(item.draft.name).font(.subheadline.bold()).lineLimit(1)
            HStack {
                Text(ClothingCategory(rawValue: item.draft.categoryCode)?.tryOnDisplayName ?? "未知分类")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case let .supported(slot) = ClothingToTryOnSlotMapper().slot(for: item.draft.categoryCode) {
                    Button { add(slot) } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                        .accessibilityLabel("添加 \(item.draft.name) 到 \(slot.displayName)")
                        .accessibilityIdentifier("tryon.add.\(item.id.uuidString)")
                }
            }
        }
        .padding(9)
        .background(.background, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(.separator.opacity(0.65))
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            switch ClothingToTryOnSlotMapper().slot(for: item.draft.categoryCode) {
            case let .supported(slot): Button("添加到\(slot.displayName)") { add(slot) }
            case .unsupported: Text("此分类暂不支持试衣")
            }
        }
    }
}

private struct TryOnSlotView: View {
    let slot: TryOnSlot
    @Bindable var model: TryOnViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(slot.displayName, systemImage: slot.systemImage).font(.subheadline.bold())
            let ids = model.session.garmentIDs(in: slot)
            if ids.isEmpty {
                Text("拖入\(slot.emptyPrompt)").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 42)
            } else {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if let item = model.clothingRecord(id: id) {
                        HStack {
                            TryOnAssetImage(resources: [item.thumbnailResourceID, item.processedResourceID].compactMap { $0 }, loader: model.imageLoader).frame(width: 38, height: 46)
                            Text(item.draft.name).lineLimit(1)
                            Spacer()
                            if slot.permitsMultipleItems {
                                Button { model.moveAccessories(fromOffsets: IndexSet(integer: index), toOffset: max(0, index - 1)) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                                Button { model.moveAccessories(fromOffsets: IndexSet(integer: index), toOffset: min(ids.count, index + 2)) } label: { Image(systemName: "arrow.down") }.disabled(index == ids.count - 1)
                            }
                            Button { model.removeClothing(id, from: slot) } label: { Image(systemName: "xmark.circle") }
                                .accessibilityLabel("移除 \(item.draft.name)")
                                .accessibilityIdentifier("tryon.remove.\(slot.rawValue).\(id.uuidString)")
                        }
                    } else {
                        Label("衣物已不可用", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.55)))
        .dropDestination(for: ClothingDragPayload.self) { payloads, _ in
            payloads.reduce(false) { accepted, payload in model.addClothing(payload.clothingID, to: slot) || accepted }
        } isTargeted: { _ in }
        .accessibilityIdentifier("tryon.slot.\(slot.rawValue)")
    }
}

private struct TryOnAssetImage: View {
    let resources: [StorageResourceID]
    let loader: any TryOnResourceLoading
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.25))
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(2) }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .task(id: resources) {
            image = nil
            for resource in resources {
                if let data = try? await loader.data(for: resource), let decoded = NSImage(data: data) { image = decoded; return }
            }
        }
    }
}

extension TryOnSlot {
    var displayName: String {
        switch self {
        case .upperBody: "上衣"
        case .outerwear: "外套"
        case .lowerBody: "下装"
        case .footwear: "鞋履"
        case .accessories: "配饰"
        }
    }

    fileprivate var emptyPrompt: String {
        switch self {
        case .upperBody: "一件上衣"
        case .outerwear: "一件外套"
        case .lowerBody: "一件下装"
        case .footwear: "一双鞋"
        case .accessories: "配饰"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .upperBody: "tshirt"
        case .outerwear: "jacket"
        case .lowerBody: "figure.walk"
        case .footwear: "shoe"
        case .accessories: "handbag"
        }
    }
}

extension ClothingCategory {
    var tryOnDisplayName: String {
        switch self {
        case .tops: "上装"
        case .outerwear: "外套"
        case .bottoms: "下装"
        case .dresses: "连衣裙"
        case .footwear: "鞋履"
        case .accessories: "配饰"
        case .other: "其他"
        }
    }
}
