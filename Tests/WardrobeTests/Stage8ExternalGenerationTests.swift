import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Wardrobe

@MainActor
final class Stage8ExternalGenerationTests: XCTestCase {
    func testPackageUsesDeterministicFilesAndPromptAttachmentOrder() async throws {
        let fixture = try makeFixture(additionalPersonImages: 2, includeAllGarmentSlots: true)
        let workspace = RecordingExternalWorkspace()
        let builder = ExternalGenerationPackageBuilder(loader: fixture.loader, workspace: workspace, now: { Date(timeIntervalSince1970: 123) })
        let package = try await builder.build(session: fixture.session, person: fixture.references, clothing: fixture.clothing)

        XCTAssertEqual(package.imageAttachments.map(\.fileName), [
            "01-person-primary.png", "02-person-reference-01.png", "03-person-reference-02.png",
            "10-upper-body.png", "20-outerwear.png", "30-lower-body.png", "40-footwear.png",
            "50-accessory-01.png", "51-accessory-02.png",
        ])
        for index in package.imageAttachments.indices {
            XCTAssertTrue(package.manifest.prompt.contains("图\(index + 1)："))
        }
        XCTAssertTrue(package.manifest.prompt.contains("图4：上衣"))
        XCTAssertTrue(package.manifest.prompt.contains("图7：鞋子"))
        XCTAssertFalse(package.manifest.prompt.contains("图10："))
        let files = await workspace.files()
        XCTAssertEqual(String(decoding: try XCTUnwrap(files.first { $0.name == "prompt.txt" }?.data), as: UTF8.self), package.manifest.prompt)
        let manifestData = try XCTUnwrap(files.first { $0.name == "manifest.json" }?.data)
        let manifestText = String(decoding: manifestData, as: UTF8.self)
        XCTAssertFalse(manifestText.contains("/Users/"))
        XCTAssertFalse(manifestText.localizedCaseInsensitiveContains("api key"))
        XCTAssertEqual(try JSONDecoder.stage8.decode(ExternalGenerationManifest.self, from: manifestData).packageID, package.id)
        XCTAssertEqual(package.manifest.source, .chatGPTManual)
    }

    func testPackageOmitsEmptySlotsAndUsesProcessedThenOriginal() async throws {
        let fixture = try makeFixture(additionalPersonImages: 0, includeAllGarmentSlots: false, processedTop: false)
        let workspace = RecordingExternalWorkspace()
        let package = try await ExternalGenerationPackageBuilder(loader: fixture.loader, workspace: workspace)
            .build(session: fixture.session, person: fixture.references, clothing: fixture.clothing)
        XCTAssertEqual(package.imageAttachments.map(\.fileName), ["01-person-primary.png", "10-upper-body.png"])
        let requested = await fixture.loader.resources()
        XCTAssertTrue(requested.contains(fixture.references.primaryImage!.processedResourceID!))
        XCTAssertTrue(requested.contains(fixture.clothing[0].originalResourceID))
    }

    func testPackageValidationAndMissingResourceFailures() async throws {
        let fixture = try makeFixture()
        let builder = ExternalGenerationPackageBuilder(loader: fixture.loader, workspace: RecordingExternalWorkspace())
        var noPerson = fixture.session; noPerson.selectPerson(profileID: nil, referenceImageIDs: [])
        await assertExternalError(.noPerson) { try await builder.build(session: noPerson, person: fixture.references, clothing: fixture.clothing) }
        var noGarment = fixture.session; noGarment.clearGarments()
        await assertExternalError(.noGarments) { try await builder.build(session: noGarment, person: fixture.references, clothing: fixture.clothing) }
        let missing = ExternalGenerationPackageBuilder(loader: FailingExternalLoader(), workspace: RecordingExternalWorkspace())
        await assertExternalError(.missingResource) { try await missing.build(session: fixture.session, person: fixture.references, clothing: fixture.clothing) }
    }

    func testWorkspacePublishesPromptManifestAndCanDeleteOnlyPackage() async throws {
        let root = try makeRoot()
        let workspace = try ExternalGenerationWorkspace(rootURL: root)
        let packageID = ExternalGenerationPackageID()
        let formal = root.appendingPathComponent("generations/formal/result.png")
        try FileManager.default.createDirectory(at: formal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pngData.write(to: formal)
        let directory = try await workspace.publish(packageID: packageID, files: [
            ExternalGenerationFile(name: "01-person-primary.png", data: Self.pngData),
            ExternalGenerationFile(name: "prompt.txt", data: Data("prompt".utf8)),
            ExternalGenerationFile(name: "manifest.json", data: Data("{}".utf8)),
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("prompt.txt").path))
        try await workspace.deletePackage(packageID: packageID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: formal.path))
    }

    func testClipboardOrLauncherFailureDoesNotDestroyPreparedPackage() async throws {
        let fixture = try makeFixture()
        let workspace = RecordingExternalWorkspace()
        let workflow = ExternalGenerationWorkflow(
            builder: ExternalGenerationPackageBuilder(loader: fixture.loader, workspace: workspace),
            clipboard: TestClipboard(succeeds: false),
            launcher: TestLauncher(openSucceeds: false, revealSucceeds: false),
            workspace: workspace
        )
        let result = try await workflow.prepare(session: fixture.session, person: fixture.references, clothing: fixture.clothing)
        XCTAssertFalse(result.promptCopied)
        XCTAssertFalse(result.chatGPTOpened)
        XCTAssertFalse(result.finderOpened)
        let publishedFiles = await workspace.files()
        XCTAssertFalse(publishedFiles.isEmpty)
    }

    func testResultImporterAcceptsPNGAndJPEGAndPersistsV1Snapshots() async throws {
        for type in [UTType.png, .jpeg] {
            let fixture = try makeFixture()
            let root = try makeRoot()
            let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
            let importer = ExternalGenerationResultImporter(repository: fixture.repository, storage: storage)
            let data = try makeImageData(type: type)
            let source = root.appendingPathComponent("input-\(UUID().uuidString)")
            try data.write(to: source)
            let imported = try await importer.importResult(from: source, package: fixture.package)
            let record = try XCTUnwrap(fixture.repository.generationRecord(id: imported.generationID))
            XCTAssertEqual(record.providerID, "external-chatgpt-manual")
            XCTAssertEqual(record.statusCode, GenerationStatus.succeeded.rawValue)
            XCTAssertEqual(record.prompt, fixture.package.manifest.prompt)
            XCTAssertEqual(record.personInputs.count, 1)
            XCTAssertEqual(record.garmentInputs.count, 1)
            XCTAssertEqual(record.garmentInputs.first?.slotCode, TryOnSlot.upperBody.rawValue)
            let storedData = try await storage.read(imported.resultResourceID)
            let thumbnailExists = try await storage.exists(imported.thumbnailResourceID)
            XCTAssertEqual(storedData, data)
            XCTAssertTrue(thumbnailExists)
        }
    }

    func testResultImporterSupportsHEICWhenRuntimeEncoderIsAvailable() async throws {
        let data: Data
        do { data = try makeImageData(type: .heic) }
        catch { throw XCTSkip("This ImageIO runtime cannot encode the HEIC fixture.") }
        let fixture = try makeFixture()
        let root = try makeRoot()
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
        let source = root.appendingPathComponent("input.heic")
        try data.write(to: source)
        let imported = try await ExternalGenerationResultImporter(repository: fixture.repository, storage: storage)
            .importResult(from: source, package: fixture.package)
        let resultExists = try await storage.exists(imported.resultResourceID)
        XCTAssertTrue(resultExists)
    }

    func testResultImporterRejectsInvalidImageWithoutCreatingGeneration() async throws {
        let fixture = try makeFixture()
        let root = try makeRoot()
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
        let source = root.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: source)
        await assertExternalError(.invalidResultImage) {
            try await ExternalGenerationResultImporter(repository: fixture.repository, storage: storage)
                .importResult(from: source, package: fixture.package)
        }
        XCTAssertTrue(try fixture.repository.allPersistedResourceIDStrings().filter { $0.hasPrefix("generations/") }.isEmpty)
    }

    private func makeFixture(
        additionalPersonImages: Int = 0,
        includeAllGarmentSlots: Bool = false,
        processedTop: Bool = true
    ) throws -> ExternalFixture {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let profile = PersonProfile(name: "测试人物", isDefault: true)
        try repository.insert(profile)
        var imageRecords: [PersonImageRecord] = []
        for index in 0...additionalPersonImages {
            let id = UUID()
            let original = try resource(.person, id, .original(fileExtension: "png"))
            let processed = try resource(.person, id, .processed)
            let image = PersonImage(id: id, profile: profile, isPrimary: index == 0, originalResourceID: original.rawValue, processedResourceID: processed.rawValue)
            try repository.insert(image)
            imageRecords.append(PersonImageRecord(id: id, profileID: profile.id, isPrimary: index == 0, originalResourceID: original, processedResourceID: processed, thumbnailResourceID: nil, pixelWidth: 1, pixelHeight: 1, createdAt: Date(timeIntervalSince1970: Double(index)), updatedAt: .now))
        }
        let slotData: [(TryOnSlot, ClothingCategory, String)] = includeAllGarmentSlots ? [
            (.upperBody, .tops, "上衣"), (.outerwear, .outerwear, "外套"), (.lowerBody, .bottoms, "裤子"),
            (.footwear, .footwear, "鞋子"), (.accessories, .accessories, "包"), (.accessories, .accessories, "帽子"),
        ] : [(.upperBody, .tops, "上衣")]
        var clothing: [ClothingRecord] = []
        var session = TryOnSession(personProfileID: profile.id, selectedPersonImageIDs: imageRecords.map(\.id))
        for (index, tuple) in slotData.enumerated() {
            let id = UUID(), original = try resource(.garment, id, .original(fileExtension: "png")), processed = try resource(.garment, id, .processed)
            let hasProcessed = index != 0 || processedTop
            let model = ClothingItem(id: id, name: tuple.2, categoryCode: tuple.1.rawValue, originalResourceID: original.rawValue, processedResourceID: hasProcessed ? processed.rawValue : nil)
            try repository.insert(model)
            clothing.append(ClothingRecord(id: id, draft: ClothingDraft(name: tuple.2, categoryCode: tuple.1.rawValue), originalResourceID: original, processedResourceID: hasProcessed ? processed : nil, thumbnailResourceID: nil, archivedAt: nil, createdAt: .now, updatedAt: .now))
            session.add(clothingID: id, to: tuple.0)
        }
        try repository.save()
        let references = PersonReferenceSet(profileID: profile.id, primaryImage: imageRecords[0], additionalImages: Array(imageRecords.dropFirst()))
        let loader = RecordingExternalLoader(data: Self.pngData)
        let attachment = ExternalGenerationAttachment(id: imageRecords[0].id, fileName: "01-person-primary.png", role: .personPrimary, resourceID: imageRecords[0].processedResourceID!, personImageID: imageRecords[0].id, clothingItemID: nil, slot: nil, sortOrder: 0, displayName: "人物")
        let garment = ExternalGenerationAttachment(id: clothing[0].id, fileName: "10-upper-body.png", role: .garment, resourceID: clothing[0].processedResourceID ?? clothing[0].originalResourceID, personImageID: nil, clothingItemID: clothing[0].id, slot: .upperBody, sortOrder: 0, displayName: clothing[0].draft.name)
        let manifest = ExternalGenerationManifest(schemaVersion: 1, workflowVersion: ExternalGenerationManifest.workflowVersion, packageID: ExternalGenerationPackageID(), createdAt: .now, personProfileID: profile.id, attachments: [attachment, garment], prompt: "测试 Prompt", source: .chatGPTManual)
        return ExternalFixture(repository: repository, references: references, clothing: clothing, session: session, loader: loader, package: ExternalGenerationPackage(manifest: manifest, directoryURL: URL(fileURLWithPath: "/transient/not-persisted")))
    }

    private func resource(_ kind: StorageOwnerKind, _ id: UUID, _ resourceKind: StorageResourceKind) throws -> StorageResourceID {
        try StorageResourceID(owner: StorageOwner(kind: kind, id: id), kind: resourceKind)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WardrobeStage8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
        return root
    }

    private func makeImageData(type: UTType) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil), let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private static let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

private struct ExternalFixture {
    let repository: SwiftDataWardrobeRepository
    let references: PersonReferenceSet
    let clothing: [ClothingRecord]
    let session: TryOnSession
    let loader: RecordingExternalLoader
    let package: ExternalGenerationPackage
}

private actor RecordingExternalLoader: TryOnResourceLoading {
    let data: Data
    private var requested: [StorageResourceID] = []
    init(data: Data) { self.data = data }
    func data(for resourceID: StorageResourceID) -> Data { requested.append(resourceID); return data }
    func resources() -> [StorageResourceID] { requested }
}

private struct FailingExternalLoader: TryOnResourceLoading {
    func data(for _: StorageResourceID) async throws -> Data { throw CocoaError(.fileReadNoSuchFile) }
}

private actor RecordingExternalWorkspace: ExternalGenerationWorkspaceServing {
    private var published: [ExternalGenerationFile] = []
    func publish(packageID: ExternalGenerationPackageID, files: [ExternalGenerationFile]) -> URL {
        published = files
        return URL(fileURLWithPath: "/temporary/\(packageID.description)")
    }
    func deletePackage(packageID _: ExternalGenerationPackageID) { published = [] }
    func files() -> [ExternalGenerationFile] { published }
}

@MainActor
private final class TestClipboard: ClipboardServing {
    let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func copy(_: String) -> Bool { succeeds }
}

@MainActor
private final class TestLauncher: ExternalAILaunching {
    let openSucceeds: Bool, revealSucceeds: Bool
    init(openSucceeds: Bool, revealSucceeds: Bool) { self.openSucceeds = openSucceeds; self.revealSucceeds = revealSucceeds }
    func openChatGPT() -> Bool { openSucceeds }
    func revealInFinder(_: URL) -> Bool { revealSucceeds }
}

private extension JSONDecoder {
    static var stage8: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

@MainActor
private func assertExternalError<T>(_ expected: ExternalGenerationError, operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await operation(); XCTFail("Expected error", file: file, line: line) }
    catch let error as ExternalGenerationError { XCTAssertEqual(error, expected, file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
