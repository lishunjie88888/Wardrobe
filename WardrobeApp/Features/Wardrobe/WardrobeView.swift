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
        GeometryReader { geometry in
            let detailWidth = min(max(geometry.size.width * 0.32, 330), 390)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    wardrobeHeader
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if case .content = model.state {
                        Text("共 \(model.items.count) 件衣物")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                    }
                }
                .layoutPriority(1)

                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { isChoosingImage = true } label: {
                            Label("添加衣服", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isImporting)
                    }
                    .padding(14)
                    Divider()

                    if let item = model.selectedItem {
                    ClothingDetailView(
                        item: item,
                        loader: model.imageLoader,
                        onEdit: { editDraft = item.draft; editingItem = item },
                        onFavorite: { model.toggleFavorite(item) },
                        onArchive: { model.setArchived(item, value: !item.isArchived) },
                        onDelete: { prepareDelete(item) }
                    )
                    } else {
                        ContentUnavailableView("选择衣物", systemImage: "tshirt", description: Text("查看衣物详情和管理操作。"))
                    }
                }
                .frame(width: detailWidth)
                .frame(maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .navigationTitle("我的衣橱")
        .accessibilityIdentifier("wardrobe.feature")
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

    private var wardrobeHeader: some View {
        HStack(spacing: 12) {
            TextField("搜索衣物名称、品牌、标签…", text: $model.query.searchText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.query.searchText) { _, _ in model.searchChanged() }
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
                    ForEach(Season.clothingSeasons, id: \.rawValue) { season in
                        Button {
                            model.query.seasonCode = season.rawValue
                        } label: {
                            if model.query.seasonCode == season.rawValue {
                                Label(season.displayName, systemImage: "checkmark")
                            } else {
                                Text(season.displayName)
                            }
                        }
                    }
                }
                Divider()
                Button("清除筛选") { model.clearFilters() }
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Picker("排序", selection: $model.query.sort) {
                Text("最近添加").tag(ClothingSort.newest)
                Text("最近修改").tag(ClothingSort.recentlyUpdated)
                Text("名称").tag(ClothingSort.name)
                Text("收藏优先").tag(ClothingSort.favoritesFirst)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(16)
        .onChange(of: model.query.archive) { _, _ in model.filtersChanged() }
        .onChange(of: model.query.favoritesOnly) { _, _ in model.filtersChanged() }
        .onChange(of: model.query.categoryCode) { _, _ in model.filtersChanged() }
        .onChange(of: model.query.seasonCode) { _, _ in model.filtersChanged() }
        .onChange(of: model.query.sort) { _, _ in model.filtersChanged() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在载入衣橱…")
        case .empty:
            emptyState(
                title: "衣橱还是空的",
                systemImage: "cabinet",
                description: "添加第一件衣服，建立你的本地衣橱。",
                actionTitle: "添加第一件衣服"
            ) { isChoosingImage = true }
        case .filteredEmpty:
            emptyState(
                title: "没有找到衣物",
                systemImage: "magnifyingglass",
                description: "没有符合当前搜索或筛选条件的衣物。",
                actionTitle: "清除筛选"
            ) { model.clearFilters() }
        case let .error(message):
            emptyState(
                title: "无法载入",
                systemImage: "exclamationmark.triangle",
                description: message,
                actionTitle: "重试"
            ) { model.load() }
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

    private func emptyState(
        title: String,
        systemImage: String,
        description: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if !item.draft.seasonCodes.isEmpty {
                Text(item.draft.seasonCodes.map(Season.displayName(for:)).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
        VStack(spacing: 0) {
            HStack(spacing: 34) {
                Text("详情")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Text("搭配记录")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .overlay(alignment: .bottomLeading) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 44, height: 2)
                    .padding(.leading, 18)
            }

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    ZStack(alignment: .topTrailing) {
                        ClothingAssetImage(record: item, loader: loader, loadThumbnailFirst: false)
                            .frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                        Button(action: onEdit) { Image(systemName: "pencil") }
                            .buttonStyle(.bordered)
                            .padding(8)
                    }

                    detailRow("名称", value: item.draft.name)
                    detailRow("类别", value: ClothingCategory(rawValue: item.draft.categoryCode)?.displayName ?? "其他 / 未知")
                    detailRow("品牌", value: item.draft.brand ?? "—")
                    detailRow("颜色", value: item.draft.colorCodes.isEmpty ? "—" : item.draft.colorCodes.joined(separator: "、"))
                    detailRow("季节", value: item.draft.seasonCodes.isEmpty ? "—" : item.draft.seasonCodes.map(Season.displayName(for:)).joined(separator: "、"))
                    detailRow("风格", value: item.draft.styleCodes.isEmpty ? "—" : item.draft.styleCodes.joined(separator: "、"))
                    detailRow("材质", value: item.draft.materials.isEmpty ? "—" : item.draft.materials.joined(separator: "、"))
                    detailRow("标签", value: item.draft.tags.isEmpty ? "—" : item.draft.tags.joined(separator: "、"))
                    if let notes = item.draft.notes {
                        detailRow("备注", value: notes, multiline: true)
                    }

                    HStack {
                        Text("收藏")
                        Spacer()
                        Button(action: onFavorite) {
                            Image(systemName: item.draft.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(item.draft.isFavorite ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wardrobe.detail.favorite")
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Menu {
                    Button(item.isArchived ? "恢复" : "归档", action: onArchive)
                    Divider()
                    Button("永久删除…", role: .destructive, action: onDelete)
                } label: {
                    Text("更多")
                }
                Spacer()
                Button("编辑", action: onEdit)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("wardrobe.detail.edit")
            }
            .padding(14)
        }
    }

    private func detailRow(_ title: String, value: String, multiline: Bool = false) -> some View {
        HStack(alignment: multiline ? .top : .center, spacing: 10) {
            Text(title)
                .frame(width: 42, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(multiline ? 4 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .font(.subheadline)
    }
}

private struct ClothingAssetImage: View {
    let record: ClothingRecord
    let loader: any ClothingImageLoading
    var loadThumbnailFirst: Bool = true
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: record.id) {
            image = nil; failed = false
            let resources = loadThumbnailFirst ? record.gridResourceIDs : record.detailResourceIDs
            for resource in resources {
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
                    TextField("风格", text: list($draft.styleCodes))
                    TextField("材质", text: list($draft.materials))
                    TextField("标签", text: list($draft.tags))
                }
                Section("适用季节（可多选）") {
                    HStack(spacing: 10) {
                        ForEach(Season.clothingSeasons, id: \.rawValue) { season in
                            Button {
                                toggleSeason(season)
                            } label: {
                                Label(
                                    season.displayName,
                                    systemImage: draft.seasonCodes.contains(season.rawValue) ? "checkmark.circle.fill" : "circle"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(draft.seasonCodes.contains(season.rawValue) ? .accentColor : .secondary)
                            .accessibilityIdentifier("wardrobe.editor.season.\(season.rawValue)")
                        }
                    }
                    Text("可以同时选择多个季节，例如春季和秋季。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private func toggleSeason(_ season: Season) {
        if let index = draft.seasonCodes.firstIndex(of: season.rawValue) {
            draft.seasonCodes.remove(at: index)
        } else {
            draft.seasonCodes.append(season.rawValue)
        }
        let order = Dictionary(uniqueKeysWithValues: Season.clothingSeasons.enumerated().map { ($0.element.rawValue, $0.offset) })
        draft.seasonCodes.sort { (order[$0] ?? Int.max) < (order[$1] ?? Int.max) }
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

private extension Season {
    static let clothingSeasons: [Season] = [.spring, .summer, .autumn, .winter]

    var displayName: String {
        switch self {
        case .spring: "春季"
        case .summer: "夏季"
        case .autumn: "秋季"
        case .winter: "冬季"
        case .allSeason: "四季"
        }
    }

    static func displayName(for code: String) -> String {
        Season(rawValue: code)?.displayName ?? code
    }
}
