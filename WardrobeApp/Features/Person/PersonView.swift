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
    @State private var profileSearchText = ""

    init(dependencies: PersonFeatureDependencies) {
        _model = State(initialValue: PersonViewModel(dependencies: dependencies))
    }

    var body: some View {
        VStack(spacing: 0) {
            personHeader
            Divider()
            Group {
                switch model.state {
                case .loading:
                    ProgressView("正在载入人物资料…")
                case .empty:
                    profileEmptyState(
                        title: "还没有人物资料",
                        systemImage: "person.crop.rectangle.stack",
                        description: "添加你的第一组全身参考照片，用于之后的 AI 试衣。",
                        actionTitle: "添加人物"
                    ) {
                        draft = PersonDraft()
                        creating = true
                    }
                case let .error(message):
                    profileEmptyState(
                        title: "无法载入",
                        systemImage: "exclamationmark.triangle",
                        description: message,
                        actionTitle: "重试"
                    ) { model.load() }
                case .content:
                    if let profile = model.selectedProfile {
                        personDashboard(profile)
                    } else {
                        ContentUnavailableView("选择人物", systemImage: "person.crop.rectangle.stack", description: Text("查看并管理人物参考照片。"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("我的形象")
        .accessibilityIdentifier("person.feature")
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

    private var filteredProfiles: [PersonProfileRecord] {
        let query = profileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.profiles }
        return model.profiles.filter { $0.draft.name.localizedCaseInsensitiveContains(query) }
    }

    private var personHeader: some View {
        HStack(spacing: 12) {
            Picker("人物", selection: $model.selectedID) {
                ForEach(model.profiles) { profile in
                    Text(profile.draft.name).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 280)

            TextField("搜索人物…", text: $profileSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            Picker("人物状态", selection: $model.archiveFilter) {
                Text("使用中").tag(PersonArchiveFilter.active)
                Text("已归档").tag(PersonArchiveFilter.archived)
                Text("全部").tag(PersonArchiveFilter.all)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: model.archiveFilter) { _, _ in model.load() }

            Spacer()
            Button {
                draft = PersonDraft()
                creating = true
            } label: {
                Label("添加人物", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func personDashboard(_ profile: PersonProfileRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GeometryReader { geometry in
                    let mainWidth = min(max(geometry.size.width * 0.32, 280), 380)
                    let detailWidth = min(max(geometry.size.width * 0.27, 270), 330)

                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("人物资料").font(.headline)
                            ZStack(alignment: .topLeading) {
                                PersonResourceImage(
                                    resourceID: profile.primaryImage?.processedResourceID ?? profile.primaryImage?.originalResourceID,
                                    loader: model.imageLoader
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                                Text("主图")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor, in: Capsule())
                                    .padding(10)
                            }
                        }
                        .padding(16)
                        .frame(width: mainWidth)
                        .frame(maxHeight: .infinity)

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("参考照片（\(profile.images.count)）")
                                    .font(.headline)
                                Spacer()
                                Button { choosingImage = true } label: {
                                    Label("添加参考照", systemImage: "plus")
                                }
                                .disabled(model.isImporting)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 145), spacing: 12)], spacing: 12) {
                                ForEach(profile.images) { image in
                                    Button { previewImage = image } label: {
                                        ZStack(alignment: .topLeading) {
                                            PersonResourceImage(resourceID: image.thumbnailResourceID ?? image.processedResourceID, loader: model.imageLoader)
                                                .frame(height: 150)
                                                .frame(maxWidth: .infinity)
                                                .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                                            if image.isPrimary {
                                                Text("主图")
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(.white)
                                                    .padding(5)
                                                    .background(Color.accentColor, in: Capsule())
                                                    .padding(6)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        if !image.isPrimary {
                                            Button("设为主图") { model.setPrimary(imageID: image.id, profileID: profile.id) }
                                        }
                                        Button("查看大图") { previewImage = image }
                                        Divider()
                                        Button("删除照片…", role: .destructive) { prepareImageDelete(image) }
                                    }
                                    .accessibilityIdentifier("person.image.\(image.id.uuidString)")
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()

                        personDetailPanel(profile)
                            .frame(width: detailWidth)
                            .frame(maxHeight: .infinity)
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.65)))
                }
                .frame(height: 510)

                Text("人物列表（\(filteredProfiles.count)）")
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(filteredProfiles) { item in
                            Button { model.selectedID = item.id } label: {
                                HStack(spacing: 12) {
                                    PersonResourceImage(resourceID: item.preferredThumbnailResourceID, loader: model.imageLoader)
                                        .frame(width: 58, height: 66)
                                        .clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(item.draft.name).font(.headline)
                                            if item.isDefault {
                                                Text("默认")
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                        }
                                        Text("\(item.images.count) 张参考照")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 12)
                                }
                                .padding(14)
                                .frame(width: 250, alignment: .leading)
                                .background(item.id == model.selectedID ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.id == model.selectedID ? Color.accentColor : Color.secondary.opacity(0.25)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("person.profile.\(item.id.uuidString)")
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
            .padding(18)
        }
    }

    private func personDetailPanel(_ profile: PersonProfileRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("详细信息").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("姓名").font(.caption).foregroundStyle(.secondary)
                Text(profile.draft.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("备注").font(.caption).foregroundStyle(.secondary)
                Text(profile.draft.notes ?? "暂无备注")
                    .foregroundStyle(profile.draft.notes == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    .padding(8)
                    .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认人物")
                    Text("AI 试衣间优先使用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { profile.isDefault },
                    set: { if $0 && !profile.isDefault { model.setDefault(profileID: profile.id) } }
                ))
                .labelsHidden()
            }
            Spacer()
            HStack {
                Menu {
                    Button(profile.isArchived ? "恢复" : "归档") {
                        model.setArchived(profileID: profile.id, value: !profile.isArchived)
                    }
                    Divider()
                    Button("永久删除…", role: .destructive) { prepareProfileDelete(profile) }
                } label: { Text("更多") }
                Spacer()
                Button("编辑") {
                    draft = profile.draft
                    editing = profile
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var profileList: some View {
        switch model.state {
        case .loading: ProgressView("正在载入人物资料…")
        case .empty:
            profileEmptyState(
                title: "还没有人物资料",
                systemImage: "person.crop.rectangle.stack",
                description: "添加你的第一组全身参考照片，用于之后的 AI 试衣。",
                actionTitle: "添加人物"
            ) {
                draft = PersonDraft()
                creating = true
            }
        case let .error(message):
            profileEmptyState(
                title: "无法载入",
                systemImage: "exclamationmark.triangle",
                description: message,
                actionTitle: "重试"
            ) { model.load() }
        case .content:
            List(model.profiles, selection: $model.selectedID) { profile in
                PersonProfileRow(profile: profile, loader: model.imageLoader)
                    .tag(profile.id)
                    .accessibilityIdentifier("person.profile.\(profile.id.uuidString)")
            }
        }
    }

    private func profileEmptyState(
        title: String,
        systemImage: String,
        description: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
