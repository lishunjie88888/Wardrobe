import AppKit
import SwiftUI

struct OutfitView: View {
    @State private var model: OutfitViewModel
    let openTryOn: (OutfitLoadResult) -> Void
    let goToTryOn: () -> Void
    @State private var editingDraft = OutfitDraft()
    @State private var showsEditor = false
    @State private var deleteTarget: OutfitRecord?

    init(dependencies: OutfitFeatureDependencies, openTryOn: @escaping (OutfitLoadResult) -> Void, goToTryOn: @escaping () -> Void) {
        _model = State(initialValue: OutfitViewModel(dependencies: dependencies))
        self.openTryOn = openTryOn
        self.goToTryOn = goToTryOn
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.outfits.isEmpty {
                emptyState
            } else {
                HSplitView {
                    outfitGrid.frame(minWidth: 430)
                    if let outfit = model.selectedOutfit { detail(outfit).frame(minWidth: 330, idealWidth: 390) }
                }
            }
        }
        .navigationTitle("穿搭")
        .accessibilityIdentifier("outfit.feature")
        .task { model.load() }
        .sheet(isPresented: $showsEditor) {
            OutfitDraftSheet(title: "编辑穿搭", draft: $editingDraft) {
                model.update(editingDraft)
                showsEditor = false
            }
        }
        .alert("永久删除穿搭？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("永久删除", role: .destructive) {
                if let target = deleteTarget { model.permanentlyDelete(target) }
                deleteTarget = nil
            }
        } message: { Text("删除穿搭不会删除衣橱中的衣物。此操作不可撤销。") }
        .alert("穿搭提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") {}
        } message: { Text(model.message ?? "") }
        .confirmationDialog("载入穿搭", isPresented: Binding(get: { model.pendingLoad?.requiresConfirmation == true }, set: { if !$0 { model.pendingLoad = nil } })) {
            Button("继续载入可用衣物") { completeLoad() }
            Button("取消", role: .cancel) { model.pendingLoad = nil }
        } message: { Text(loadSummary) }
        .onChange(of: model.pendingLoad) { _, result in
            if result?.requiresConfirmation == false { completeLoad() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("搜索名称或备注", text: $model.query.searchText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                .accessibilityIdentifier("outfit.search").onSubmit { model.load() }
            Toggle("仅收藏", isOn: $model.query.favoritesOnly).toggleStyle(.button)
            Picker("范围", selection: $model.query.archive) {
                Text("未归档").tag(OutfitArchiveFilter.active)
                Text("已归档").tag(OutfitArchiveFilter.archived)
                Text("全部").tag(OutfitArchiveFilter.all)
            }.frame(width: 120)
            Picker("排序", selection: $model.query.sort) {
                Text("最近修改").tag(OutfitSort.recentlyUpdated)
                Text("最新创建").tag(OutfitSort.newest)
                Text("名称").tag(OutfitSort.name)
                Text("收藏优先").tag(OutfitSort.favoritesFirst)
            }.frame(width: 135)
            Button("应用") { model.load() }
            Spacer()
            Button { goToTryOn() } label: { Label("前往 AI 试衣间", systemImage: "sparkles.rectangle.stack") }
        }.padding(14)
    }

    @ViewBuilder private var emptyState: some View {
        if model.query.hasActiveFilters {
            VStack(spacing: 14) {
                ContentUnavailableView("没有符合条件的穿搭", systemImage: "line.3.horizontal.decrease.circle", description: Text("清除搜索和筛选后重试。"))
                Button("清除筛选") { model.clearFilters() }
            }
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView("还没有保存的穿搭", systemImage: "square.grid.2x2", description: Text("在 AI 试衣间中搭配衣物后，可以保存到这里。"))
                Button("前往 AI 试衣间") { goToTryOn() }
            }
        }
    }

    private var outfitGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)], spacing: 14) {
                ForEach(model.outfits) { outfit in
                    OutfitCard(outfit: outfit, loader: model.imageLoader) {
                        model.selection = outfit.id
                    } favorite: { model.toggleFavorite(outfit) }
                    .accessibilityIdentifier("outfit.card.\(outfit.id.uuidString)")
                    .contextMenu {
                        Button(outfit.isArchived ? "恢复" : "归档") { model.setArchived(outfit, archived: !outfit.isArchived) }
                        Button("永久删除", role: .destructive) { deleteTarget = outfit }
                    }
                }
            }.padding(16)
        }
    }

    private func detail(_ outfit: OutfitRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(outfit.draft.name).font(.title2.bold())
                        if outfit.isArchived { Label("已归档", systemImage: "archivebox").foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button { model.toggleFavorite(outfit) } label: { Image(systemName: outfit.draft.isFavorite ? "star.fill" : "star") }
                        .accessibilityIdentifier("outfit.favorite.\(outfit.id.uuidString)")
                }
                if let notes = outfit.draft.notes { Text(notes).foregroundStyle(.secondary) }
                LabeledContent("创建", value: outfit.createdAt.formatted())
                LabeledContent("修改", value: outfit.updatedAt.formatted())
                Divider()
                ForEach(TryOnSlot.allCases, id: \.self) { slot in
                    let items = outfit.items.filter { $0.slotCode == slot.rawValue }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(slot.displayName).font(.headline)
                            ForEach(items) { item in OutfitItemRow(item: item, loader: model.imageLoader) }
                        }
                    }
                }
                let invalid = outfit.items.filter { $0.resolvedSlot == nil }
                if !invalid.isEmpty {
                    Text("未知槽位").font(.headline)
                    ForEach(invalid) { item in OutfitItemRow(item: item, loader: model.imageLoader) }
                }
                Divider()
                Button("在 AI 试衣间中打开") { model.preflight(outfit) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("outfit.openInTryOn")
                HStack {
                    Button("编辑") { editingDraft = outfit.draft; showsEditor = true }
                    Button(outfit.isArchived ? "恢复" : "归档") { model.setArchived(outfit, archived: !outfit.isArchived) }
                        .accessibilityIdentifier("outfit.archive.\(outfit.id.uuidString)")
                    Button("永久删除", role: .destructive) { deleteTarget = outfit }
                        .accessibilityIdentifier("outfit.delete.\(outfit.id.uuidString)")
                }
            }.padding(20)
        }
    }

    private var loadSummary: String {
        guard let result = model.pendingLoad else { return "" }
        var lines = ["此穿搭有 \(result.availableItems.count + result.unavailableItems.count) 件衣物：", "可载入：\(result.availableItems.count)"]
        let labels: [(OutfitUnavailableReason, String)] = [(.archived, "已归档"), (.missing, "已删除"), (.invalidSlot, "槽位无效"), (.incompatible, "不兼容")]
        for (reason, label) in labels where result.unavailableCount(reason) > 0 { lines.append("\(label)：\(result.unavailableCount(reason))") }
        lines.append("将只载入当前可用的 \(result.availableItems.count) 件衣物。")
        return lines.joined(separator: "\n")
    }

    private func completeLoad() {
        guard let result = model.pendingLoad else { return }
        model.pendingLoad = nil
        openTryOn(result)
    }
}

struct OutfitDraftSheet: View {
    let title: String
    @Binding var draft: OutfitDraft
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            TextField("名称", text: $draft.name)
            TextField("备注", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }), axis: .vertical).lineLimit(3...6)
            Toggle("收藏", isOn: $draft.isFavorite)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 430)
    }
}

private struct OutfitCard: View {
    let outfit: OutfitRecord
    let loader: any ClothingImageLoading
    let select: () -> Void
    let favorite: () -> Void
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(Array(outfit.items.prefix(4))) { item in OutfitThumbnail(resource: item.preferredThumbnailResourceID, loader: loader).frame(height: 70) }
                    if outfit.items.isEmpty { Image(systemName: "photo.on.rectangle.angled").frame(maxWidth: .infinity, minHeight: 144) }
                }
                HStack { Text(outfit.draft.name).font(.headline).lineLimit(1); Spacer(); Button(action: favorite) { Image(systemName: outfit.draft.isFavorite ? "star.fill" : "star") }.buttonStyle(.plain) }
                HStack { Text("\(outfit.items.count) 件衣物"); Spacer(); Text(outfit.updatedAt, style: .relative) }.font(.caption).foregroundStyle(.secondary)
                if outfit.isArchived { Text("已归档").font(.caption.bold()).foregroundStyle(.orange) }
            }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        }.buttonStyle(.plain)
    }
}

private struct OutfitItemRow: View {
    let item: OutfitItemRecord
    let loader: any ClothingImageLoading
    var body: some View {
        HStack {
            OutfitThumbnail(resource: item.preferredThumbnailResourceID, loader: loader).frame(width: 54, height: 62)
            VStack(alignment: .leading) { Text(item.displayName); Text(status).font(.caption).foregroundStyle(statusColor) }
            Spacer(); Text(item.resolvedSlot?.displayName ?? item.slotCode).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var status: String {
        if !item.hasCurrentClothing { return "衣物已删除" }
        if !item.currentClothingIsActive { return "衣物已归档" }
        guard let slot = item.resolvedSlot else { return "Slot 不兼容" }
        if case let .supported(mapped) = ClothingToTryOnSlotMapper().slot(for: item.currentCategoryCode ?? ""), mapped == slot { return item.preferredThumbnailResourceID == nil ? "图片不可用" : "可用" }
        return "Slot 不兼容"
    }
    private var statusColor: Color { status == "可用" ? .secondary : .orange }
}

private struct OutfitThumbnail: View {
    let resource: StorageResourceID?
    let loader: any ClothingImageLoading
    @State private var image: NSImage?
    var body: some View {
        ZStack { RoundedRectangle(cornerRadius: 6).fill(.quaternary); if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "photo").foregroundStyle(.secondary) } }
            .task(id: resource) { image = nil; if let resource, let data = try? await loader.data(for: resource) { image = NSImage(data: data) } }
    }
}
