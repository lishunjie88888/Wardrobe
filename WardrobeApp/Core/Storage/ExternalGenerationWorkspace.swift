import AppKit
import Foundation

actor ExternalGenerationWorkspace: ExternalGenerationWorkspaceServing {
    private let fileManager: FileManager
    private let exportRoot: URL
    private let stagingRoot: URL

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        exportRoot = rootURL.appendingPathComponent("external-generations", isDirectory: true)
        stagingRoot = rootURL.appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    func publish(packageID: ExternalGenerationPackageID, files: [ExternalGenerationFile]) throws -> URL {
        let directoryName = "ChatGPT-TryOn-\(packageID.description)"
        let destination = exportRoot.appendingPathComponent(directoryName, isDirectory: true)
        let staging = stagingRoot.appendingPathComponent("external-\(packageID.description)", isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path), !fileManager.fileExists(atPath: staging.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            for file in files {
                guard Self.isSafeFileName(file.name) else { throw CocoaError(.fileWriteInvalidFileName) }
                try file.data.write(to: staging.appendingPathComponent(file.name), options: [.atomic])
            }
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            if fileManager.fileExists(atPath: staging.path) { try? fileManager.removeItem(at: staging) }
            throw error
        }
    }

    func deletePackage(packageID: ExternalGenerationPackageID) throws {
        let directory = exportRoot.appendingPathComponent("ChatGPT-TryOn-\(packageID.description)", isDirectory: true)
        guard directory.deletingLastPathComponent().standardizedFileURL == exportRoot.standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

@MainActor
final class SystemClipboardService: ClipboardServing {
    func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

@MainActor
final class SystemExternalAILauncher: ExternalAILaunching {
    private let workspace: NSWorkspace
    private let chatGPTBundleIdentifier = "com.openai.chat"
    private let webURL = URL(string: "https://chatgpt.com/")!

    init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    func openChatGPT() -> Bool {
        if let appURL = workspace.urlForApplication(withBundleIdentifier: chatGPTBundleIdentifier) {
            if workspace.open(appURL) {
                return true
            }
        }
        return workspace.open(webURL)
    }

    func revealInFinder(_ directoryURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return false
        }
        workspace.activateFileViewerSelecting([directoryURL])
        return true
    }
}

extension StorageService: ExternalGenerationResultStorageServing {
    func saveExternalGenerationResult(_ data: Data, mediaType: String, generationID: UUID) throws -> StoredGenerationResources {
        try saveGenerationResult(data, mediaType: mediaType, generationID: generationID)
    }

    func deleteExternalGenerationResult(generationID: UUID) throws {
        try deleteResourceDirectory(for: StorageOwner(kind: .generation, id: generationID))
    }
}
