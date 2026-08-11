import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WardrobeView: View {
    @State private var model: WardrobeViewModel
    @State private var isChoosingImage = false
    @State private var pendingImageURL: URL?
    @State private var addDraft = ClothingDraft()
    @State private var editDraft = ClothingDraft()
    @State private var editingItem: ClothingRecord?
    @State private var deletingItem: ClothingRecord?
    @State private var deleteImpact: ClothingDeleteImpact?

    init(dependencies: WardrobeFeatureDependencies) {
        _model = State(initialValue: WardrobeViewModel(dependencies: dependencies))
    }

    var body: some View {
        HSplitView {
            content
                .frame(minWidth: 440)
            if let item = model.selectedItem {
                ClothingDetailView(
                    item: item,
                    loader: model.imageLoader,
                    onEdit: { editDraft = item.draft; editingItem = item },
                    onFavorite: { model.toggleFavorite(item) },
                    onArchive: { model.setArchived(item, value: !item.isArchived) },
                    onDelete: { prepareDelete(item) }
                )
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            }
        }
        .navigationTitle("我的衣橱")
        .accessibilityIdentifier("wardrobe.feature")
        .searchable(text: $model.query.searchText, prompt: "搜索名称、品牌、颜色、材质或标签")
        .onChange(of: model.query.searchText) { _, _ in model.searchChanged() }
        .toolbar { toolbarContent }
        .task { model.load() }
        .fileImporter(
            isPresented: $isChoosingImage,
            allowedContentTypes: [.jpeg, .png, .heic, .heif],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                pendingImageURL = url
                addDraft = ClothingDraft()
            } else if case .failure = result {
                model.presentedError = "无法打开所选文件。"
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingImageURL != nil },
            set: { if !$0 { pendingImageURL = nil } }
        )) {
            if let url = pendingImageURL {
                ClothingEditorSheet(title: "添加衣服", imageURL: url, draft: $addDraft, isSaving: model.isImporting) {
                    model.importClothing(from: url, draft: addDraft)
                } onCancel: {
                    model.cancelImport()
                    pendingImageURL = nil
                }
                .onChange(of: model.isImporting) { wasImporting, isImporting in
                    if wasImporting && !isImporting && model.presentedError == nil { pendingImageURL = nil }
                }
            }
        }
        .sheet(item: $editingItem) { item in
            ClothingEditorSheet(title: "编辑衣物", imageURL: nil, draft: $editDraft, isSaving: false) {
                if model.update(id: item.id, draft: editDraft) { editingItem = nil }
            } onCancel: { editingItem = nil }
        }
        .alert("永久删除衣物？", isPresented: Binding(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil; deleteImpact = nil } }
        ), presenting: deletingItem) { item in
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { model.permanentlyDelete(item) }
        } message: { _ in
            Text(deleteMessage)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("好") {} } message: { Text(model.presentedError ?? "") }
        .alert("资源状态", isPresented: Binding(
            get: { model.cleanupNotice != nil },
            set: { if !$0 { model.cleanupNotice = nil } }
        )) { Button("好") {} } message: { Text(model.cleanupNotice ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在载入衣橱…")
        case .empty:
            ContentUnavailableView("衣橱还是空的", systemImage: "cabinet", description: Text("添加第一件衣服，建立你的本地衣橱。"))
                .overlay(alignment: .bottom) { Button("添加第一件衣服") { isChoosingImage = true }.padding(.bottom, 80) }
        case .filteredEmpty:
            ContentUnavailableView.search(text: model.query.searchText)
                .overlay(alignment: .bottom) { Button("清除筛选") { model.clearFilters() }.padding(.bottom, 80) }
        case let .error(message):
            ContentUnavailableView("无法载入", systemImage: "exclamationmark.triangle", description: Text(message))
                .overlay(alignment: .bottom) { Button("重试") { model.load() }.padding(.bottom, 80) }
        case .content:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)], spacing: 18) {
                    ForEach(model.items) { item in
                        Button { model.selectedID = item.id } label: {
                            ClothingCard(item: item, loader: model.imageLoader, isSelected: item.id == model.selectedID)
                        }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("wardrobe.item.\(item.id.uuidString)")
                            .contextMenu {
                                Button(item.draft.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(item) }
                                Button("编辑") { editDraft = item.draft; editingItem = item }
                                Button(item.isArchived ? "恢复" : "归档") { model.setArchived(item, value: !item.isArchived) }
                                Divider()
                                Button("永久删除…", role: .destructive) { prepareDelete(item) }
                            }
                    }
                }
                .padding()
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("归档状态", selection: $model.query.archive) {
                    Text("使用中").tag(ClothingArchiveFilter.active)
                    Text("已归档").tag(ClothingArchiveFilter.archived)
                    Text("全部").tag(ClothingArchiveFilter.all)
                }
                Toggle("仅收藏", isOn: $model.query.favoritesOnly)
                Menu("分类") {
                    Button("全部分类") { model.query.categoryCode = nil }
                    ForEach(ClothingCategory.allCases, id: \.rawValue) { category in
                        Button(category.displayName) { model.query.categoryCode = category.rawValue }
                    }
                }
                Menu("季节") {
                    Button("全部季节") { model.query.seasonCode = nil }
                    ForEach(Season.allCases, id: \.rawValue) { value in
                        Button(value.rawValue) { model.query.seasonCode = value.rawValue }
                    }
                }
                Menu("风格") {
                    Button("全部风格") { model.query.styleCode = nil }
                    ForEach(StyleTag.allCases, id: \.rawValue) { value in
                        Button(value.rawValue) { model.query.styleCode = value.rawValue }
                    }
                }
                let availableColors = Set(model.items.flatMap(\.draft.colorCodes)).sorted()
                if !availableColors.isEmpty {
                    Menu("颜色") {
                        Button("全部颜色") { model.query.colorCode = nil }
                        ForEach(availableColors, id: \.self) { value in
                            Button(value) { model.query.colorCode = value }
                        }
                    }
                }
                Button("清除筛选") { model.clearFilters() }
            } label: { Label("筛选", systemImage: "line.3.horizontal.decrease.circle") }
            .onChange(of: model.query.archive) { _, _ in model.filtersChanged() }
            .onChange(of: model.query.favoritesOnly) { _, _ in model.filtersChanged() }
            .onChange(of: model.query.categoryCode) { _, _ in model.filtersChanged() }
            .onChange(of: model.query.seasonCode) { _, _ in model.filtersChanged() }
            .onChange(of: model.query.styleCode) { _, _ in model.filtersChanged() }
            .onChange(of: model.query.colorCode) { _, _ in model.filtersChanged() }

            Picker("排序", selection: $model.query.sort) {
                Text("最近添加").tag(ClothingSort.newest)
                Text("最近修改").tag(ClothingSort.recentlyUpdated)
                Text("名称").tag(ClothingSort.name)
                Text("收藏优先").tag(ClothingSort.favoritesFirst)
            }
            .pickerStyle(.menu)
            .onChange(of: model.query.sort) { _, _ in model.filtersChanged() }

            Button { isChoosingImage = true } label: { Label("添加衣服", systemImage: "plus") }
                .disabled(model.isImporting)
        }
    }

    private var deleteMessage: String {
        guard let impact = deleteImpact else { return "此操作不可恢复。为安全起见，无法确认引用时图片会被保留。" }
        if impact.hasHistoricalReferences {
            return "此操作不可恢复。发现 \(impact.outfitSnapshotCount) 个穿搭快照和 \(impact.generationSnapshotCount) 个生成快照；记录关系会置空，仍被引用的图片会保留。"
        }
        return "此操作不可恢复。衣物元数据及确认无其他引用的图片将被删除。"
    }

    private func prepareDelete(_ item: ClothingRecord) {
        guard let impact = model.deleteImpact(for: item) else { return }
        deleteImpact = impact
        deletingItem = item
    }
}

private struct ClothingCard: View {
    let item: ClothingRecord
    let loader: any ClothingImageLoading
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClothingAssetImage(record: item, loader: loader)
                .frame(height: 170)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(item.draft.name).font(.headline).lineLimit(1)
                Spacer()
                if item.draft.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.red) }
            }
            Text(ClothingCategory(rawValue: item.draft.categoryCode)?.displayName ?? "其他 / 未知")
                .font(.caption).foregroundStyle(.secondary)
            if let brand = item.draft.brand { Text(brand).font(.caption).lineLimit(1) }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct ClothingDetailView: View {
    let item: ClothingRecord
    let loader: any ClothingImageLoading
    let onEdit: () -> Void
    let onFavorite: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ClothingAssetImage(record: item, loader: loader).frame(height: 260)
                HStack { Text(item.draft.name).font(.title2.bold()); Spacer(); Button(action: onFavorite) { Image(systemName: item.draft.isFavorite ? "heart.fill" : "heart") }.accessibilityIdentifier("wardrobe.detail.favorite") }
                LabeledContent("分类", value: ClothingCategory(rawValue: item.draft.categoryCode)?.displayName ?? "其他 / 未知")
                if let brand = item.draft.brand { LabeledContent("品牌", value: brand) }
                if !item.draft.tags.isEmpty { LabeledContent("标签", value: item.draft.tags.joined(separator: "、")) }
                if let notes = item.draft.notes { Text(notes).foregroundStyle(.secondary) }
                Divider()
                HStack { Button("编辑", action: onEdit).accessibilityIdentifier("wardrobe.detail.edit"); Button(item.isArchived ? "恢复" : "归档", action: onArchive).accessibilityIdentifier("wardrobe.detail.archive") }
                Button("永久删除…", role: .destructive, action: onDelete)
            }.padding()
        }
    }
}

private struct ClothingAssetImage: View {
    let record: ClothingRecord
    let loader: any ClothingImageLoading
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: record.id) {
            image = nil; failed = false
            for resource in [record.processedResourceID, record.thumbnailResourceID].compactMap({ $0 }) {
                if let data = try? await loader.data(for: resource), let decoded = NSImage(data: data) { image = decoded; return }
            }
            failed = true
        }
    }
}

private struct ClothingEditorSheet: View {
    let title: String
    let imageURL: URL?
    @Binding var draft: ClothingDraft
    let isSaving: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.title2.bold()).padding()
            Form {
                if let imageURL, let preview = NSImage(contentsOf: imageURL) {
                    Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 180)
                }
                Section("基本信息") {
                    TextField("名称", text: $draft.name).accessibilityIdentifier("wardrobe.editor.name")
                    Picker("分类", selection: $draft.categoryCode) {
                        ForEach(ClothingCategory.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                    }
                    TextField("子分类", text: optional($draft.subcategoryCode))
                    TextField("品牌", text: optional($draft.brand))
                    Toggle("收藏", isOn: $draft.isFavorite)
                }
                Section("属性（用逗号分隔）") {
                    TextField("颜色", text: list($draft.colorCodes))
                    TextField("季节", text: list($draft.seasonCodes))
                    TextField("风格", text: list($draft.styleCodes))
                    TextField("材质", text: list($draft.materials))
                    TextField("标签", text: list($draft.tags))
                }
                Section("备注") { TextEditor(text: optional($draft.notes)).frame(minHeight: 70) }
            }
            Divider()
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                if isSaving { ProgressView().controlSize(.small); Button("取消导入", action: onCancel) }
                else { Button("保存", action: onSave).accessibilityIdentifier("wardrobe.editor.save").keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding()
        }
        .frame(width: 560, height: 680)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func list(_ binding: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.joined(separator: ", ") },
            set: { binding.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        )
    }
}

private extension ClothingCategory {
    var displayName: String {
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
