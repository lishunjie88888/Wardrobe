import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                backupSection
                restoreSection
                restoreResultSection
                progressSection
                errorSection
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("设置")
        .sheet(isPresented: $viewModel.showsPreview) { previewSheet }
        .sheet(isPresented: $viewModel.showsConfirmRestore) { confirmSheet }
    }

    // MARK: Backup

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("备份与恢复", systemImage: "externaldrive")
                .font(.title3.bold())
            Text("备份包含衣物、人物照片和生成结果。当前 V1 备份未加密，请妥善保管。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                guard let url = viewModel.chooseBackupDestination() else { return }
                Task { await viewModel.createBackup(to: url) }
            } label: {
                Label("创建备份…", systemImage: "externaldrive.badge.plus")
            }
            .accessibilityIdentifier("backup.create")
            .disabled(viewModel.coordinator.isBusy || viewModel.coordinator.isPendingRestorePresent)

            if let summary = viewModel.coordinator.lastBackupSummary {
                backupSummary(summary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func backupSummary(_ summary: BackupSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("备份已创建", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            Text("衣物 \(summary.recordCounts.clothingItems) · 人物 \(summary.recordCounts.personProfiles) · 穿搭 \(summary.recordCounts.outfits) · 生成历史 \(summary.recordCounts.generations)")
                .font(.caption)
            Text("资源 \(summary.assetCount) 个 · \(ByteCountFormatter.string(fromByteCount: summary.totalAssetBytes, countStyle: .file))")
                .font(.caption)
            if summary.unreferencedFileCount > 0 {
                Text("资料库中存在 \(summary.unreferencedFileCount) 个未被引用的文件，未包含在备份中。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("backup.summary")
    }

    // MARK: Restore

    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("恢复将用备份内容替换当前 Wardrobe 资料库，不会合并或追加。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                guard let url = viewModel.chooseBackupPackage() else { return }
                Task { await viewModel.validateSelectedPackage(url) }
            } label: {
                Label("从备份恢复…", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("backup.restore.select")
            .disabled(viewModel.coordinator.isBusy || viewModel.coordinator.isPendingRestorePresent)

            if viewModel.coordinator.isPendingRestorePresent {
                Label("已存在等待完成的恢复事务，请退出并重新打开 Wardrobe 以完成恢复。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let ready = viewModel.coordinator.restoreReady {
                readyView(ready)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func readyView(_ ready: BackupRestoreReadyInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("恢复已准备好", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("备份内容已在隔离位置完成验证。请退出并重新打开 Wardrobe，启动时会自动完成恢复。")
                .font(.callout)
            Text("将恢复：衣物 \(ready.restoredRecordCounts.clothingItems) · 人物 \(ready.restoredRecordCounts.personProfiles) · 穿搭 \(ready.restoredRecordCounts.outfits) · 生成历史 \(ready.restoredRecordCounts.generations)")
                .font(.caption)
            Button("退出 Wardrobe", role: .destructive) {
                viewModel.quitApp()
            }
            .accessibilityIdentifier("backup.restore.quit")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("backup.restore.ready")
    }

    // MARK: Restore result

    @ViewBuilder
    private var restoreResultSection: some View {
        if let result = viewModel.restoreResult {
            VStack(alignment: .leading, spacing: 8) {
                if result.rolledBack {
                    Label("恢复未完成。原资料库已恢复，未发生替换。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("恢复已完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("衣物 \(result.restoredRecordCounts.clothingItems) · 人物 \(result.restoredRecordCounts.personProfiles) · 穿搭 \(result.restoredRecordCounts.outfits) · 生成历史 \(result.restoredRecordCounts.generations) · 资源 \(result.restoredAssetCount) 个")
                        .font(.callout)
                }
                Text("完成时间：\(result.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("backup.restore.result")
        }
    }

    // MARK: Progress & errors

    @ViewBuilder
    private var progressSection: some View {
        if let phase = viewModel.coordinator.phase, viewModel.coordinator.isBusy {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                Text(phase.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("backup.progress")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.coordinator.lastError {
            Label(error.localizedDescription, systemImage: "xmark.octagon")
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityIdentifier("backup.error")
        }
    }

    // MARK: Sheets

    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("恢复预览")
                .font(.title3.bold())
            if let preview = viewModel.preview {
                switch preview.validationStatus {
                case .valid:
                    previewDetails(preview)
                    HStack {
                        Button("取消") { viewModel.showsPreview = false }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("替换并恢复…", role: .destructive) {
                            viewModel.showsPreview = false
                            viewModel.showsConfirmRestore = true
                        }
                        .accessibilityIdentifier("backup.restore.preview")
                    }
                case let .blocked(reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    HStack {
                        Spacer()
                        Button("关闭") { viewModel.showsPreview = false }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            } else if let error = viewModel.previewError {
                Label(error.localizedDescription, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                HStack {
                    Spacer()
                    Button("关闭") { viewModel.showsPreview = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func previewDetails(_ preview: BackupPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("备份时间：\(preview.createdAt.formatted(date: .abbreviated, time: .shortened))")
            Text("备份格式：V\(preview.backupFormatVersion) · 数据版本：\(preview.schemaVersion) · 存储布局：\(preview.storageLayoutVersion)")
            Text("衣物 \(preview.recordCounts.clothingItems) · 人物 \(preview.recordCounts.personProfiles) · 人物照片 \(preview.recordCounts.personImages) · 穿搭 \(preview.recordCounts.outfits) · 生成历史 \(preview.recordCounts.generations)")
            Text("资源 \(preview.assetCount) 个 · \(ByteCountFormatter.string(fromByteCount: preview.totalAssetBytes, countStyle: .file))")
            Text("这将替换当前资料库，当前资料库会在替换过程中保留回滚快照。")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("backup.restore.preview")
    }

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认替换资料库")
                .font(.title3.bold())
            Text("恢复将用备份内容替换当前 Wardrobe 资料库，且无法撤销。当前资料库会在替换过程中保留回滚快照。")
            HStack {
                Button("取消") { viewModel.showsConfirmRestore = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("替换并恢复", role: .destructive) {
                    Task { await viewModel.confirmRestore() }
                }
                .accessibilityIdentifier("backup.restore.confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

#Preview {
    let container = try! WardrobeModelContainerFactory.inMemory()
    let configuration = StorageConfiguration(
        rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeSettingsPreview", isDirectory: true)
    )
    let storage = try! StorageService(configuration: configuration)
    SettingsView(viewModel: SettingsViewModel(coordinator: BackupCoordinator(
        container: container,
        storageService: storage,
        configuration: configuration
    )))
}
