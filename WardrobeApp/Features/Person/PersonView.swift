import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PersonView: View {
    @State private var model: PersonViewModel
    @State private var creating = false
    @State private var editing: PersonProfileRecord?
    @State private var draft = PersonDraft()
    @State private var choosingImage = false
    @State private var pendingImageURL: URL?
    @State private var previewImage: PersonImageRecord?
    @State private var deletingImage: PersonImageRecord?
    @State private var deletingProfile: PersonProfileRecord?
    @State private var imageImpact: PersonImageDeleteImpact?
    @State private var profileImpact: PersonProfileDeleteImpact?

    init(dependencies: PersonFeatureDependencies) {
        _model = State(initialValue: PersonViewModel(dependencies: dependencies))
    }

    var body: some View {
        HSplitView {
            profileList.frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            if let profile = model.selectedProfile {
                PersonDetailView(
                    profile: profile,
                    loader: model.imageLoader,
                    isImporting: model.isImporting,
                    onEdit: { draft = profile.draft; editing = profile },
                    onAddImage: { choosingImage = true },
                    onDefault: { model.setDefault(profileID: profile.id) },
                    onArchive: { model.setArchived(profileID: profile.id, value: !profile.isArchived) },
                    onDeleteProfile: { prepareProfileDelete(profile) },
                    onPreview: { previewImage = $0 },
                    onPrimary: { model.setPrimary(imageID: $0.id, profileID: profile.id) },
                    onDeleteImage: { prepareImageDelete($0) }
                )
                .frame(minWidth: 460)
            } else {
                ContentUnavailableView("选择人物", systemImage: "person.crop.rectangle.stack", description: Text("查看并管理人物参考照片。"))
                    .frame(minWidth: 460)
            }
        }
        .navigationTitle("我的形象")
        .accessibilityIdentifier("person.feature")
        .toolbar {
            ToolbarItemGroup {
                Picker("人物状态", selection: $model.archiveFilter) {
                    Text("使用中").tag(PersonArchiveFilter.active)
                    Text("已归档").tag(PersonArchiveFilter.archived)
                    Text("全部").tag(PersonArchiveFilter.all)
                }
                .pickerStyle(.menu)
                .onChange(of: model.archiveFilter) { _, _ in model.load() }
                Button { draft = PersonDraft(); creating = true } label: { Label("添加人物", systemImage: "plus") }
            }
        }
        .task { model.load() }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.jpeg, .png, .heic, .heif], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                pendingImageURL = url
            } else if case .failure = result { model.presentedError = "无法打开所选文件。" }
        }
        .sheet(isPresented: Binding(get: { pendingImageURL != nil }, set: { if !$0 { pendingImageURL = nil } })) {
            if let url = pendingImageURL, let profile = model.selectedProfile {
                PersonImageImportSheet(url: url, profileName: profile.draft.name, isImporting: model.isImporting) {
                    model.importImage(from: url, profileID: profile.id)
                } onCancel: {
                    model.cancelImport(); pendingImageURL = nil
                }
                .onChange(of: model.isImporting) { wasImporting, isImporting in
                    if wasImporting && !isImporting && model.presentedError == nil { pendingImageURL = nil }
                }
            }
        }
        .sheet(isPresented: $creating) {
            PersonEditorSheet(title: "添加人物", draft: $draft) { if model.create(draft: draft) { creating = false } } onCancel: { creating = false }
        }
        .sheet(item: $editing) { profile in
            PersonEditorSheet(title: "编辑人物", draft: $draft) { if model.update(id: profile.id, draft: draft) { editing = nil } } onCancel: { editing = nil }
        }
        .sheet(item: $previewImage) { image in
            PersonImagePreview(image: image, loader: model.imageLoader)
        }
        .alert("删除参考照片？", isPresented: Binding(get: { deletingImage != nil }, set: { if !$0 { deletingImage = nil; imageImpact = nil } }), presenting: deletingImage) { image in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.deleteImage(image) }
        } message: { _ in Text(imageDeleteMessage) }
        .alert("永久删除人物？", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil; profileImpact = nil } }), presenting: deletingProfile) { profile in
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { model.deleteProfile(profile) }
        } message: { _ in Text(profileDeleteMessage) }
        .alert("操作失败", isPresented: Binding(get: { model.presentedError != nil }, set: { if !$0 { model.presentedError = nil } })) { Button("好") {} } message: { Text(model.presentedError ?? "") }
        .alert("资源状态", isPresented: Binding(get: { model.cleanupNotice != nil }, set: { if !$0 { model.cleanupNotice = nil } })) { Button("好") {} } message: { Text(model.cleanupNotice ?? "") }
    }

    @ViewBuilder private var profileList: some View {
        switch model.state {
        case .loading: ProgressView("正在载入人物资料…")
        case .empty:
            ContentUnavailableView("还没有人物资料", systemImage: "person.crop.rectangle.stack", description: Text("添加你的第一组全身参考照片，用于之后的 AI 试衣。"))
                .overlay(alignment: .bottom) { Button("添加人物") { draft = PersonDraft(); creating = true }.padding(.bottom, 70) }
        case let .error(message):
            ContentUnavailableView("无法载入", systemImage: "exclamationmark.triangle", description: Text(message))
                .overlay(alignment: .bottom) { Button("重试") { model.load() }.padding(.bottom, 70) }
        case .content:
            List(model.profiles, selection: $model.selectedID) { profile in
                PersonProfileRow(profile: profile, loader: model.imageLoader)
                    .tag(profile.id)
                    .accessibilityIdentifier("person.profile.\(profile.id.uuidString)")
            }
        }
    }

    private var imageDeleteMessage: String {
        guard let impact = imageImpact else { return "此操作不可恢复。无法确认引用时图片文件会被保留。" }
        return impact.generationSnapshotCount > 0
            ? "这张照片被 \(impact.generationSnapshotCount) 个生成快照引用。人物图片记录会删除，历史快照及其资源会保留。"
            : "图片记录及确认无其他引用的文件将被永久删除。"
    }

    private var profileDeleteMessage: String {
        guard let impact = profileImpact else { return "此操作不可恢复。无法确认引用时图片文件会被保留。" }
        return "将删除人物资料和 \(impact.imageCount) 张图片记录。历史中的 \(impact.generationImageSnapshotCount) 个图片快照会保留，仍被引用的文件不会删除。"
    }

    private func prepareImageDelete(_ image: PersonImageRecord) {
        guard let impact = model.imageDeleteImpact(imageID: image.id) else { return }
        imageImpact = impact; deletingImage = image
    }

    private func prepareProfileDelete(_ profile: PersonProfileRecord) {
        guard let impact = model.profileDeleteImpact(profileID: profile.id) else { return }
        profileImpact = impact; deletingProfile = profile
    }
}

private struct PersonProfileRow: View {
    let profile: PersonProfileRecord
    let loader: any PersonImageLoading

    var body: some View {
        HStack(spacing: 10) {
            PersonResourceImage(resourceID: profile.preferredThumbnailResourceID, loader: loader)
                .frame(width: 54, height: 64).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(profile.draft.name).font(.headline); if profile.isDefault { Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint) } }
                Text("\(profile.images.count) 张参考照片").font(.caption).foregroundStyle(.secondary)
                if profile.isArchived { Text("已归档").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 4)
    }
}

private struct PersonDetailView: View {
    let profile: PersonProfileRecord
    let loader: any PersonImageLoading
    let isImporting: Bool
    let onEdit: () -> Void
    let onAddImage: () -> Void
    let onDefault: () -> Void
    let onArchive: () -> Void
    let onDeleteProfile: () -> Void
    let onPreview: (PersonImageRecord) -> Void
    let onPrimary: (PersonImageRecord) -> Void
    let onDeleteImage: (PersonImageRecord) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        HStack { Text(profile.draft.name).font(.largeTitle.bold()); if profile.isDefault { Label("默认人物", systemImage: "checkmark.seal.fill").foregroundStyle(.tint) } }
                        if let notes = profile.draft.notes { Text(notes).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Menu { Button("编辑", action: onEdit); Button(profile.isArchived ? "恢复" : "归档", action: onArchive); Divider(); Button("永久删除…", role: .destructive, action: onDeleteProfile) } label: { Image(systemName: "ellipsis.circle") }
                }
                HStack {
                    Button("编辑", action: onEdit).accessibilityIdentifier("person.detail.edit")
                    Button(profile.isDefault ? "已是默认人物" : "设为默认人物", action: onDefault).disabled(profile.isDefault || profile.isArchived).accessibilityIdentifier("person.detail.default")
                    Button(action: onAddImage) { Label("添加照片", systemImage: "plus") }.disabled(isImporting).accessibilityIdentifier("person.detail.addImage")
                    if isImporting { ProgressView("正在导入并处理…").controlSize(.small) }
                }
                Text("参考照片").font(.title2.bold())
                if profile.images.isEmpty {
                    ContentUnavailableView("尚未添加参考照片", systemImage: "photo.on.rectangle.angled", description: Text("添加清晰的全身照作为后续试衣参考。"))
                        .frame(minHeight: 220)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], spacing: 14) {
                        ForEach(profile.images) { image in
                            VStack(alignment: .leading, spacing: 7) {
                                Button { onPreview(image) } label: {
                                    PersonResourceImage(resourceID: image.thumbnailResourceID ?? image.processedResourceID, loader: loader)
                                        .frame(height: 190).frame(maxWidth: .infinity).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                                HStack {
                                    if image.isPrimary { Label("主图", systemImage: "star.fill").foregroundStyle(.tint).accessibilityIdentifier("person.image.primary.\(image.id.uuidString)") }
                                    else { Button("设为主图") { onPrimary(image) }.controlSize(.small).accessibilityIdentifier("person.image.makePrimary.\(image.id.uuidString)") }
                                    Spacer()
                                    Menu { Button("查看大图") { onPreview(image) }; Divider(); Button("删除照片…", role: .destructive) { onDeleteImage(image) } } label: { Image(systemName: "ellipsis") }
                                }
                            }
                            .accessibilityIdentifier("person.image.\(image.id.uuidString)")
                        }
                        Button(action: onAddImage) { VStack { Image(systemName: "plus").font(.largeTitle); Text("添加照片") }.frame(maxWidth: .infinity, minHeight: 190) }
                            .buttonStyle(.borderless).disabled(isImporting)
                    }
                }
            }.padding(22)
        }
    }
}

private struct PersonResourceImage: View {
    let resourceID: StorageResourceID?
    let loader: any PersonImageLoading
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "person.crop.rectangle").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: resourceID) {
            image = nil
            guard let resourceID, let data = try? await loader.data(for: resourceID) else { return }
            image = NSImage(data: data)
        }
    }
}

private struct PersonImagePreview: View {
    let image: PersonImageRecord
    let loader: any PersonImageLoading

    var body: some View {
        VStack { PersonResourceImage(resourceID: image.processedResourceID ?? image.thumbnailResourceID, loader: loader); Text(image.isPrimary ? "主参考照" : "参考照").foregroundStyle(.secondary) }
            .padding().frame(minWidth: 560, minHeight: 620)
    }
}

private struct PersonEditorSheet: View {
    let title: String
    @Binding var draft: PersonDraft
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.title2.bold()).padding()
            Form {
                TextField("姓名", text: $draft.name).accessibilityIdentifier("person.editor.name")
                TextEditor(text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 })).frame(minHeight: 100)
            }.padding()
            Divider()
            HStack { Button("取消", action: onCancel); Spacer(); Button("保存", action: onSave).keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("person.editor.save") }.padding()
        }.frame(width: 480, height: 320)
    }
}

private struct PersonImageImportSheet: View {
    let url: URL
    let profileName: String
    let isImporting: Bool
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("添加参考照片").font(.title2.bold())
            Text("将照片添加到“\(profileName)”").foregroundStyle(.secondary)
            if let preview = NSImage(contentsOf: url) {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 420)
            } else {
                ContentUnavailableView("无法预览", systemImage: "photo.badge.exclamationmark")
            }
            if isImporting { ProgressView("正在验证、导入并处理照片…") }
            HStack {
                Button(isImporting ? "取消导入" : "取消", action: onCancel)
                Spacer()
                Button("导入", action: onImport).keyboardShortcut(.defaultAction).disabled(isImporting)
            }
        }.padding(22).frame(width: 600, height: 600)
    }
}
