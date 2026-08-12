import AppKit
import SwiftUI

struct GenerationHistoryView: View {
    @State private var model: GenerationHistoryViewModel
    @State private var outfitDraft = OutfitDraft()
    @State private var compactShowsDetail = false
    let regenerate: (GenerationRegenerateRequest) -> Void

    init(dependencies: GenerationHistoryFeatureDependencies, regenerate: @escaping (GenerationRegenerateRequest) -> Void) {
        _model = State(initialValue: GenerationHistoryViewModel(dependencies: dependencies))
        self.regenerate = regenerate
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 720

            VStack(spacing: 0) {
                toolbar(compact: proxy.size.width < 700)
                Divider()
                if model.records.isEmpty { emptyState }
                else if compact {
                    compactContent
                } else {
                    HSplitView {
                        historyList(compact: false)
                            .frame(minWidth: 310, idealWidth: 380)
                        if let detail = model.detail {
                            GenerationHistoryDetail(detail: detail, model: model, regenerate: regenerate, enforcesMinimumWidth: true)
                        } else {
                            ContentUnavailableView("选择一条生成记录", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }
        }
        .navigationTitle("生成历史")
        .accessibilityIdentifier("generationHistory.feature")
        .task { model.load() }
        .sheet(isPresented: Binding(get: { model.outfitPreflight != nil }, set: { if !$0 { model.outfitPreflight = nil } })) {
            if let detail = model.detail {
                OutfitDraftSheet(title: "保存为穿搭", draft: $outfitDraft) { model.saveOutfit(detail, draft: outfitDraft) }
            }
        }
        .alert("删除这条生成记录？", isPresented: Binding(get: { model.deleteImpact != nil }, set: { if !$0 { model.deleteImpact = nil } })) {
            Button("取消", role: .cancel) { model.deleteImpact = nil }
            Button("永久删除", role: .destructive) { model.confirmDelete() }.accessibilityIdentifier("generationHistory.deleteConfirm")
        } message: {
            Text("将移除生成记录、输入快照子项和无其他引用的专属生成结果。不会删除衣物、人物、源照片或已保存穿搭。")
        }
        .alert("生成历史提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) { Button("好") {} } message: { Text(model.message ?? "") }
    }

    @ViewBuilder private var compactContent: some View {
        if compactShowsDetail, let detail = model.detail {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        compactShowsDetail = false
                    } label: {
                        Label("返回历史", systemImage: "chevron.left")
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                GenerationHistoryDetail(detail: detail, model: model, regenerate: regenerate, enforcesMinimumWidth: false)
            }
        } else {
            historyList(compact: true)
        }
    }

    private func historyList(compact: Bool) -> some View {
        List(model.records, selection: Binding(get: { model.selection }, set: {
            guard let value = $0 else { return }
            model.select(value)
            if compact { compactShowsDetail = true }
        })) { record in
            GenerationHistoryRow(record: record, loader: model.imageLoader)
                .tag(record.id)
                .accessibilityIdentifier("generationHistory.row.\(record.id.uuidString)")
                .contextMenu {
                    if record.status.isTerminal {
                        Button("打开详情") {
                            model.select(record.id)
                            if compact { compactShowsDetail = true }
                        }
                        Button("删除历史", role: .destructive) {
                            model.select(record.id)
                            if let detail = model.detail { model.preflightDelete(detail) }
                        }
                    }
                }
        }
    }

    @ViewBuilder private func toolbar(compact: Bool) -> some View {
        let filters = HStack(spacing: 12) {
            Picker("状态", selection: $model.query.status) {
                Text("全部").tag(GenerationStatusFilter.all)
                Text("成功").tag(GenerationStatusFilter.succeeded)
                Text("失败").tag(GenerationStatusFilter.failed)
                Text("已取消").tag(GenerationStatusFilter.cancelled)
                Text("进行中").tag(GenerationStatusFilter.inProgress)
            }.frame(width: 110).accessibilityIdentifier("generationHistory.statusFilter")
            Picker("Provider", selection: $model.query.providerID) {
                Text("全部 Provider").tag(String?.none)
                ForEach(model.providerIDs, id: \.self) { Text(GenerationHistoryPresentation.providerName($0)).tag(Optional($0)) }
            }.frame(width: 190).accessibilityIdentifier("generationHistory.providerFilter")
        }
        let actions = HStack(spacing: 12) {
            Button("应用") { model.load() }
            if model.query.hasActiveFilters { Button("清除筛选") { model.clearFilters() } }
            Spacer()
        }

        if compact {
            VStack(alignment: .leading, spacing: 10) {
                filters
                actions
            }
            .padding(14)
        } else {
            HStack(spacing: 12) {
                filters
                actions
            }
            .padding(14)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.query.hasActiveFilters {
            VStack(spacing: 14) {
                ContentUnavailableView("没有符合条件的生成记录", systemImage: "line.3.horizontal.decrease.circle")
                Button("清除筛选") { model.clearFilters() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("还没有生成记录", systemImage: "clock.arrow.circlepath", description: Text("在 AI 试衣间完成生成后，记录会显示在这里。"))
        }
    }
}

private struct GenerationHistoryRow: View {
    let record: GenerationHistoryRecord
    let loader: any GenerationHistoryImageLoading
    var body: some View {
        HStack(spacing: 12) {
            HistoryResourceImage(resource: record.thumbnailResourceID, loader: loader, fallback: statusIcon(record.status)).frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.personNameSnapshot).font(.headline)
                Text(record.garmentSummary.isEmpty ? "无衣物摘要" : record.garmentSummary).lineLimit(2).foregroundStyle(.secondary)
                HStack { Text(GenerationHistoryPresentation.providerName(record.providerID)); Spacer(); StatusLabel(status: record.status) }.font(.caption)
                Text(record.createdAt.formatted()).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}

private struct GenerationHistoryDetail: View {
    let detail: GenerationDetailRecord
    let model: GenerationHistoryViewModel
    let regenerate: (GenerationRegenerateRequest) -> Void
    let enforcesMinimumWidth: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("生成详情").font(.title2.bold())
                HistoryResourceImage(resource: detail.resultResourceID, loader: model.imageLoader, fallback: statusIcon(detail.status)).frame(maxWidth: .infinity).frame(height: 300)
                GroupBox("状态与 Provider") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("状态") { StatusLabel(status: detail.status) }
                        LabeledContent("Provider", value: GenerationHistoryPresentation.providerName(detail.providerID))
                        LabeledContent("Provider ID", value: detail.providerID)
                        if let modelID = detail.providerModelID { LabeledContent("模型", value: modelID) }
                        LabeledContent("创建", value: detail.createdAt.formatted())
                        if let started = detail.startedAt { LabeledContent("开始", value: started.formatted()) }
                        if let completed = detail.completedAt { LabeledContent("完成", value: completed.formatted()) }
                        LabeledContent("尝试次数", value: String(detail.attemptCount))
                        if let source = detail.sourceGenerationID { LabeledContent("来源") { Text(detail.sourceExists ? source.uuidString : "来源记录已删除") } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                inputSections
                GroupBox("Prompt") { Text(detail.prompt.isEmpty ? "未保存 Prompt" : detail.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                GroupBox("生成参数") { Text(detail.optionsText).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if detail.errorCode != nil || detail.safeErrorMessage != nil {
                    GroupBox("诊断") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let code = detail.errorCode { LabeledContent("错误代码", value: code) }
                            if let message = detail.safeErrorMessage { Text(message).textSelection(.enabled) }
                            if let request = detail.providerRequestID { DisclosureGroup("高级诊断") { Text(request).textSelection(.enabled) } }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Button("重新生成") { model.regenerate(detail, handoff: regenerate) }
                        .disabled(!detail.status.isTerminal).accessibilityIdentifier("generationHistory.regenerate")
                    if detail.status == .known(.succeeded) {
                        Button("保存为穿搭") { model.preflightSaveOutfit(detail) }.accessibilityIdentifier("generationHistory.saveOutfit")
                    }
                    Spacer()
                    Button("删除历史", role: .destructive) { model.preflightDelete(detail) }
                        .disabled(!detail.status.isTerminal).accessibilityIdentifier("generationHistory.delete")
                }
            }.padding(20)
        }
        .frame(minWidth: enforcesMinimumWidth ? 400 : nil)
        .accessibilityIdentifier("generationHistory.detail")
    }

    private var inputSections: some View {
        Group {
            GroupBox("人物输入") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(detail.persons) { item in
                        HStack { HistoryResourceImage(resource: item.resourceIDSnapshot, loader: model.imageLoader, fallback: "person.crop.rectangle").frame(width: 74, height: 94); VStack(alignment: .leading) { Text(item.personNameSnapshot).font(.headline); Text(item.hasCurrentImage && item.hasCurrentProfile ? "当前来源仍存在" : "当前来源已删除").foregroundStyle(.secondary) } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("衣物与槽位") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(detail.garments) { item in
                        HStack { HistoryResourceImage(resource: item.resourceIDSnapshot, loader: model.imageLoader, fallback: "tshirt").frame(width: 74, height: 74); VStack(alignment: .leading) { Text(item.clothingNameSnapshot).font(.headline); Text(item.resolvedSlot?.displayName ?? "未知槽位：\(item.slotCode)"); if let current = item.currentClothingName, current != item.clothingNameSnapshot { Text("当前名称：\(current)").foregroundStyle(.secondary) }; if !item.hasCurrentClothing { Text("当前衣物已删除").foregroundStyle(.orange) } } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct StatusLabel: View {
    let status: GenerationDisplayStatus
    var body: some View { Label(statusText(status), systemImage: statusIcon(status)).foregroundStyle(statusColor(status)) }
}

private struct HistoryResourceImage: View {
    let resource: StorageResourceID?
    let loader: any GenerationHistoryImageLoading
    let fallback: String
    @State private var image: NSImage?
    var body: some View {
        ZStack { RoundedRectangle(cornerRadius: 8).fill(.quaternary); if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: fallback).font(.title).foregroundStyle(.secondary) } }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: resource) { guard let resource, let data = try? await loader.data(for: resource) else { image = nil; return }; image = NSImage(data: data) }
    }
}

private func statusText(_ status: GenerationDisplayStatus) -> String {
    switch status {
    case .known(.queued): "排队中"
    case .known(.preparing): "准备中"
    case .known(.running): "生成中"
    case .known(.succeeded): "成功"
    case .known(.failed): "失败"
    case .known(.cancelled): "已取消"
    case .interrupted: "生成被中断"
    case .unknown(let raw): "未知状态（\(raw)）"
    }
}

private func statusIcon(_ status: GenerationDisplayStatus) -> String {
    switch status { case .known(.succeeded): "checkmark.circle"; case .known(.cancelled): "xmark.circle"; case .known(.queued), .known(.preparing), .known(.running): "clock"; case .known(.failed), .interrupted: "exclamationmark.triangle"; case .unknown: "questionmark.circle" }
}

private func statusColor(_ status: GenerationDisplayStatus) -> Color {
    switch status { case .known(.succeeded): .green; case .known(.cancelled): .secondary; case .known(.queued), .known(.preparing), .known(.running): .blue; case .known(.failed), .interrupted: .red; case .unknown: .orange }
}
