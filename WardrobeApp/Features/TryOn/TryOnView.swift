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

    init(dependencies: TryOnFeatureDependencies) {
        _model = State(initialValue: TryOnViewModel(dependencies: dependencies))
    }

    var body: some View {
        HSplitView {
            clothingBrowser.frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
            personCanvas.frame(minWidth: 330, idealWidth: 520)
            outfitPanel.frame(minWidth: 280, idealWidth: 330, maxWidth: 430)
        }
        .navigationTitle("AI 试衣间")
        .accessibilityIdentifier("tryon.feature")
        .task { model.load() }
        .onDisappear { model.cancelGeneration(setCancelledState: false) }
        .alert("试衣间提示", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) { Button("好") {} } message: { Text(model.message ?? "") }
    }

    private var clothingBrowser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("搜索衣橱", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("tryon.clothing.search")
                    .onSubmit { model.filtersChanged() }
                HStack {
                    Picker("分类", selection: $model.categoryCode) {
                        Text("全部分类").tag(String?.none)
                        ForEach(ClothingCategory.allCases, id: \.rawValue) { Text($0.tryOnDisplayName).tag(Optional($0.rawValue)) }
                    }
                    .labelsHidden()
                    Toggle("收藏", isOn: $model.favoritesOnly).toggleStyle(.button)
                }
                .onChange(of: model.categoryCode) { _, _ in model.filtersChanged() }
                .onChange(of: model.favoritesOnly) { _, _ in model.filtersChanged() }
            }
            .padding(12)
            Divider()
            if model.clothing.isEmpty {
                ContentUnavailableView("没有可用衣物", systemImage: "tshirt", description: Text("请先在“我的衣橱”中添加或调整筛选。"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 12) {
                        ForEach(model.clothing) { item in
                            TryOnClothingCard(item: item, loader: model.imageLoader) { slot in
                                model.addClothing(item.id, to: slot)
                            }
                            .draggable(ClothingDragPayload(clothingID: item.id))
                            .accessibilityIdentifier("tryon.clothing.\(item.id.uuidString)")
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(.background)
    }

    private var personCanvas: some View {
        VStack(spacing: 14) {
            if model.profiles.isEmpty {
                ContentUnavailableView("还没有人物资料", systemImage: "person.crop.rectangle", description: Text("请先在“我的形象”中添加人物参考照片。"))
            } else {
                HStack {
                    Picker("人物", selection: Binding(
                        get: { model.session.personProfileID },
                        set: { model.selectPerson($0) }
                    )) {
                        ForEach(model.profiles) { profile in
                            Text(profile.isDefault ? "\(profile.draft.name) · 默认" : profile.draft.name).tag(Optional(profile.id))
                        }
                    }
                    .accessibilityIdentifier("tryon.person.picker")
                    Spacer()
                    Text("Mock 工作区").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                if let profile = model.selectedProfile, let primary = model.currentReferences?.primaryImage {
                    TryOnAssetImage(resources: [primary.processedResourceID, primary.originalResourceID].compactMap { $0 }, loader: model.imageLoader)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal)
                        .accessibilityIdentifier("tryon.person.canvas")
                        .dropDestination(for: ClothingDragPayload.self) { payloads, _ in
                            payloads.reduce(false) { accepted, payload in model.addClothing(payload.clothingID) || accepted }
                        } isTargeted: { _ in }
                    HStack {
                        Text(profile.draft.name).font(.headline)
                        if profile.isDefault { Label("默认人物", systemImage: "star.fill").font(.caption).foregroundStyle(.secondary) }
                    }
                    referencePicker
                } else {
                    ContentUnavailableView("当前人物没有可用参考照片", systemImage: "photo.badge.exclamationmark", description: Text("请先为此人物添加并设置主参考照。"))
                }
                generationStatus
            }
        }
        .padding(.vertical)
        .background(.quaternary.opacity(0.18))
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
            .padding(.horizontal)
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
                Button("清空") { model.clearOutfit() }
                    .disabled(model.session.garmentCount == 0)
                    .accessibilityIdentifier("tryon.clear")
            }
            .padding()
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(TryOnSlot.allCases, id: \.self) { slot in
                        TryOnSlotView(slot: slot, model: model)
                    }
                }
                .padding()
            }
            Divider()
            VStack(spacing: 8) {
                switch model.generationState {
                case .generating, .validating:
                    Button("取消生成", role: .cancel) { model.cancelGeneration() }
                        .accessibilityIdentifier("tryon.cancel")
                default:
                    Button("生成试穿") { model.generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canGenerate)
                        .accessibilityIdentifier("tryon.generate")
                }
                Text("使用 Mock Provider · 不访问网络").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(.background)
    }
}

private struct TryOnClothingCard: View {
    let item: ClothingRecord
    let loader: any TryOnResourceLoading
    let add: (TryOnSlot?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TryOnAssetImage(resources: [item.processedResourceID, item.thumbnailResourceID].compactMap { $0 }, loader: loader)
                .frame(height: 105)
            Text(item.draft.name).font(.subheadline.bold()).lineLimit(1)
            HStack {
                Text(ClothingCategory(rawValue: item.draft.categoryCode)?.tryOnDisplayName ?? "未知分类")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case let .supported(slot) = ClothingToTryOnSlotMapper().slot(for: item.draft.categoryCode) {
                    Button { add(slot) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("添加 \(item.draft.name) 到 \(slot.displayName)")
                        .accessibilityIdentifier("tryon.add.\(item.id.uuidString)")
                }
            }
        }
        .padding(7)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
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
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)))
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
        case .upperBody: "Upper Body"
        case .outerwear: "Outerwear"
        case .lowerBody: "Lower Body"
        case .footwear: "Footwear"
        case .accessories: "Accessories"
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
