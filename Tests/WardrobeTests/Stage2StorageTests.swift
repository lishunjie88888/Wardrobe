import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Wardrobe

final class Stage2StorageTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeStage2Tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return root
    }

    private func makeStorage(
        root: URL,
        thumbnailGenerator: any ImageThumbnailGenerating = ImageIOThumbnailGenerator()
    ) throws -> StorageService {
        try StorageService(
            configuration: StorageConfiguration(rootURL: root),
            thumbnailGenerator: thumbnailGenerator
        )
    }

    func testStorageRootCreatesCompleteLayoutAndManifestIdempotently() async throws {
        let root = try makeRoot()
        let first = try makeStorage(root: root)
        let firstManifest = try await first.libraryManifest()
        let second = try makeStorage(root: root)
        let secondManifest = try await second.libraryManifest()

        XCTAssertEqual(firstManifest.storageLayoutVersion, 1)
        XCTAssertEqual(firstManifest, secondManifest)
        for directory in [
            "database", "garments", "persons", "generations", "outfits", "staging", "cache",
            "cache/previews", "cache/provider", "backups",
        ] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(directory).path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testProductionRootUsesApplicationSupportBundleDirectory() throws {
        let configuration = try StorageConfiguration.production(
            bundleIdentifier: "com.example.WardrobeStorageTests",
            environment: [:],
            isTestProcess: false
        )
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )

        XCTAssertEqual(
            configuration.rootURL.standardizedFileURL,
            applicationSupport
                .appendingPathComponent("com.example.WardrobeStorageTests", isDirectory: true)
                .appendingPathComponent("Wardrobe", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.rootURL.path))
    }

    func testUUIDResourceDirectoryIsCreatedAtControlledLocation() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())

        try await storage.createResourceDirectory(for: owner)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("garments/\(owner.directoryName)").path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testWriteReadAndExistsUseRelativeResourceReference() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let resource = try StorageResourceID(
            owner: StorageOwner(kind: .garment, id: UUID()),
            kind: .processed
        )
        let payload = Data("wardrobe".utf8)

        try await storage.write(payload, to: resource)

        let exists = try await storage.exists(resource)
        let storedPayload = try await storage.read(resource)
        XCTAssertTrue(exists)
        XCTAssertEqual(storedPayload, payload)
        XCTAssertFalse(resource.rawValue.contains(root.path))
    }

    func testServiceRebuildResolvesPersistedReferenceAtSameRoot() async throws {
        let root = try makeRoot()
        let resource = try StorageResourceID(
            owner: StorageOwner(kind: .person, id: UUID()),
            kind: .processed
        )
        let first = try makeStorage(root: root)
        try await first.write(Data([1, 2, 3]), to: resource)

        let rebuilt = try makeStorage(root: root)

        let rebuiltData = try await rebuilt.read(resource)
        XCTAssertEqual(rebuiltData, Data([1, 2, 3]))
    }

    func testJPEGImportPreservesOriginalAndCreatesBoundedThumbnail() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("incoming.jpg")
        try makeImageData(type: .jpeg, width: 1_200, height: 800).write(to: source)
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())

        let result = try await storage.importImage(from: source, for: owner)
        let thumbnailURL = root.appendingPathComponent(result.thumbnail.rawValue)
        let thumbnailMetadata = try ImageIOThumbnailGenerator().inspectImage(at: thumbnailURL)

        XCTAssertEqual(result.metadata.format, .jpeg)
        XCTAssertEqual(result.original.rawValue, "garments/\(owner.directoryName)/original.jpg")
        let storedOriginal = try await storage.read(result.original)
        XCTAssertEqual(storedOriginal, try Data(contentsOf: source))
        XCTAssertLessThanOrEqual(max(thumbnailMetadata.pixelWidth, thumbnailMetadata.pixelHeight), 512)
        XCTAssertEqual(thumbnailMetadata.format, .jpeg)
    }

    func testPNGImportUsesDetectedFormatInsteadOfSourceExtension() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("misleading.jpg")
        try makeImageData(type: .png, width: 320, height: 640).write(to: source)
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .person, id: UUID())

        let result = try await storage.importImage(from: source, for: owner)

        XCTAssertEqual(result.metadata.format, .png)
        XCTAssertEqual(result.original.rawValue, "persons/\(owner.directoryName)/original.png")
        XCTAssertEqual(
            result.processedPlaceholder?.rawValue,
            "persons/\(owner.directoryName)/processed.png"
        )
        let processedExists = try await storage.exists(try XCTUnwrap(result.processedPlaceholder))
        let thumbnailExists = try await storage.exists(result.thumbnail)
        XCTAssertFalse(processedExists)
        XCTAssertTrue(thumbnailExists)
    }

    func testHEICImportWhenSystemEncoderAndDecoderAreAvailable() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("incoming.heic")
        guard let heicData = try? makeImageData(type: .heic, width: 96, height: 64) else {
            throw XCTSkip("The active macOS ImageIO runtime cannot encode the HEIC test fixture.")
        }
        try heicData.write(to: source)
        let storage = try makeStorage(root: root)

        let result = try await storage.importImage(
            from: source,
            for: StorageOwner(kind: .garment, id: UUID())
        )

        XCTAssertEqual(result.metadata.format, .heic)
        let originalExists = try await storage.exists(result.original)
        let thumbnailExists = try await storage.exists(result.thumbnail)
        XCTAssertTrue(originalExists)
        XCTAssertTrue(thumbnailExists)
    }

    func testHEIFImportWhenSystemEncoderAndDecoderAreAvailable() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("incoming.heif")
        guard let heifData = try? makeImageData(type: .heif, width: 96, height: 64) else {
            throw XCTSkip("The active macOS ImageIO runtime cannot encode the HEIF test fixture.")
        }
        try heifData.write(to: source)
        let storage = try makeStorage(root: root)

        let result = try await storage.importImage(
            from: source,
            for: StorageOwner(kind: .person, id: UUID())
        )

        let originalExists = try await storage.exists(result.original)
        XCTAssertEqual(result.metadata.format, .heif)
        XCTAssertTrue(originalExists)
    }

    func testThumbnailAppliesImageOrientationMetadata() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("rotated.jpg")
        try makeImageData(
            type: .jpeg,
            width: 40,
            height: 80,
            orientation: 6
        ).write(to: source)
        let storage = try makeStorage(root: root)

        let result = try await storage.importImage(
            from: source,
            for: StorageOwner(kind: .garment, id: UUID())
        )
        let thumbnail = try ImageIOThumbnailGenerator().inspectImage(
            at: root.appendingPathComponent(result.thumbnail.rawValue)
        )

        XCTAssertGreaterThan(thumbnail.pixelWidth, thumbnail.pixelHeight)
    }

    func testDeleteSingleFileDoesNotDeleteSibling() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let processed = try StorageResourceID(owner: owner, kind: .processed)
        let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail)
        try await storage.write(Data([1]), to: processed)
        try await storage.write(Data([2]), to: thumbnail)

        try await storage.delete(processed)

        let processedExists = try await storage.exists(processed)
        let thumbnailExists = try await storage.exists(thumbnail)
        XCTAssertFalse(processedExists)
        XCTAssertTrue(thumbnailExists)
    }

    func testDeleteResourceDirectoryRemovesOnlyExactOwner() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let firstOwner = StorageOwner(kind: .person, id: UUID())
        let secondOwner = StorageOwner(kind: .person, id: UUID())
        let first = try StorageResourceID(owner: firstOwner, kind: .processed)
        let second = try StorageResourceID(owner: secondOwner, kind: .processed)
        try await storage.write(Data([1]), to: first)
        try await storage.write(Data([2]), to: second)

        try await storage.deleteResourceDirectory(for: firstOwner)

        let firstExists = try await storage.exists(first)
        let secondExists = try await storage.exists(second)
        XCTAssertFalse(firstExists)
        XCTAssertTrue(secondExists)
    }

    func testMissingFileReadAndDeleteReturnStableError() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let missing = try StorageResourceID(
            owner: StorageOwner(kind: .garment, id: UUID()),
            kind: .thumbnail
        )

        do {
            _ = try await storage.read(missing)
            XCTFail("Expected a missing resource error.")
        } catch {
            XCTAssertEqual(error as? StorageError, .resourceNotFound(missing))
        }
        do {
            try await storage.delete(missing)
            XCTFail("Expected a missing resource error.")
        } catch {
            XCTAssertEqual(error as? StorageError, .resourceNotFound(missing))
        }
    }

    func testImportThumbnailFailureCleansStagingAndOwnerDirectory() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("incoming.png")
        try makeImageData(type: .png, width: 64, height: 64).write(to: source)
        let storage = try makeStorage(root: root, thumbnailGenerator: FailingThumbnailGenerator())
        let owner = StorageOwner(kind: .garment, id: UUID())

        do {
            _ = try await storage.importImage(from: source, for: owner)
            XCTFail("Expected thumbnail generation to fail.")
        } catch {
            XCTAssertEqual(error as? ImageValidationError, .thumbnailEncodingFailed)
        }

        XCTAssertEqual(try directoryContents(root.appendingPathComponent("staging")).count, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("garments/\(owner.directoryName)").path
            )
        )
    }

    func testDifferentUUIDOwnersPreventFilenameCollision() async throws {
        let root = try makeRoot()
        let firstSource = root.appendingPathComponent("first.jpg")
        let secondSource = root.appendingPathComponent("second.jpg")
        let firstData = try makeImageData(type: .jpeg, width: 50, height: 60, color: (1, 0, 0, 1))
        let secondData = try makeImageData(type: .jpeg, width: 50, height: 60, color: (0, 0, 1, 1))
        try firstData.write(to: firstSource)
        try secondData.write(to: secondSource)
        let storage = try makeStorage(root: root)

        let first = try await storage.importImage(
            from: firstSource,
            for: StorageOwner(kind: .garment, id: UUID())
        )
        let second = try await storage.importImage(
            from: secondSource,
            for: StorageOwner(kind: .garment, id: UUID())
        )

        XCTAssertNotEqual(first.original.rawValue, second.original.rawValue)
        let storedFirst = try await storage.read(first.original)
        let storedSecond = try await storage.read(second.original)
        XCTAssertEqual(storedFirst, firstData)
        XCTAssertEqual(storedSecond, secondData)
    }

    func testExistingResourceIsNeverOverwritten() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let resource = try StorageResourceID(
            owner: StorageOwner(kind: .generation, id: UUID()),
            kind: .thumbnail
        )
        try await storage.write(Data([1]), to: resource)

        do {
            try await storage.write(Data([2]), to: resource)
            XCTFail("Expected an existing-resource error.")
        } catch {
            XCTAssertEqual(error as? StorageError, .resourceAlreadyExists(resource))
        }
        let stored = try await storage.read(resource)
        XCTAssertEqual(stored, Data([1]))
    }

    func testSameOwnerConcurrentWritesAreSerializedWithoutPartialFiles() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let processed = try StorageResourceID(owner: owner, kind: .processed)
        let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail)

        async let first: Void = storage.write(Data([1]), to: processed)
        async let second: Void = storage.write(Data([2]), to: thumbnail)
        _ = try await (first, second)

        let processedData = try await storage.read(processed)
        let thumbnailData = try await storage.read(thumbnail)
        XCTAssertEqual(processedData, Data([1]))
        XCTAssertEqual(thumbnailData, Data([2]))
        XCTAssertEqual(try directoryContents(root.appendingPathComponent("staging")).count, 0)
    }

    func testCompensationTransactionRollsBackOnlyRegisteredOwner() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let rollbackOwner = StorageOwner(kind: .garment, id: UUID())
        let retainedOwner = StorageOwner(kind: .garment, id: UUID())
        let rollbackResource = try StorageResourceID(owner: rollbackOwner, kind: .processed)
        let retainedResource = try StorageResourceID(owner: retainedOwner, kind: .processed)
        try await storage.write(Data([1]), to: rollbackResource)
        try await storage.write(Data([2]), to: retainedResource)
        let transaction = StorageCompensationTransaction(storage: storage)
        await transaction.register(.deleteResourceDirectory(rollbackOwner))

        let issues = await transaction.rollback()

        let rollbackExists = try await storage.exists(rollbackResource)
        let retainedExists = try await storage.exists(retainedResource)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertFalse(rollbackExists)
        XCTAssertTrue(retainedExists)
    }

    func testMovePublishesToControlledRelativeDestination() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let source = try StorageResourceID(owner: owner, kind: .processed)
        let destination = try StorageResourceID(owner: owner, kind: .thumbnail)
        try await storage.write(Data([4, 2]), to: source)

        try await storage.move(from: source, to: destination)

        let sourceExists = try await storage.exists(source)
        let destinationData = try await storage.read(destination)
        XCTAssertFalse(sourceExists)
        XCTAssertEqual(destinationData, Data([4, 2]))
    }

    func testGenerationResultIsValidatedAndPublishedWithThumbnail() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let generationID = UUID()
        let image = try makeImageData(type: .png, width: 800, height: 400)

        let result = try await storage.saveGenerationResult(
            image,
            mediaType: "image/png",
            generationID: generationID
        )

        XCTAssertEqual(
            result.result.rawValue,
            "generations/\(generationID.uuidString.lowercased())/result.png"
        )
        let resultExists = try await storage.exists(result.result)
        let thumbnailExists = try await storage.exists(result.thumbnail)
        XCTAssertTrue(resultExists)
        XCTAssertTrue(thumbnailExists)
        XCTAssertEqual(try directoryContents(root.appendingPathComponent("staging")).count, 0)
    }

    func testInvalidResourceIDsRejectEscapeAbsoluteAndNonCanonicalUUID() {
        XCTAssertThrowsError(try StorageResourceID(rawValue: "/tmp/image.jpg"))
        XCTAssertThrowsError(try StorageResourceID(rawValue: "garments/../original.jpg"))
        XCTAssertThrowsError(try StorageResourceID(rawValue: "unknown/123/original.jpg"))
        XCTAssertThrowsError(
            try StorageResourceID(
                rawValue: "garments/\(UUID().uuidString)/original.jpg"
            )
        )
        let unsafeJSON = Data("\"garments/../original.jpg\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StorageResourceID.self, from: unsafeJSON))
    }

    func testSymbolicLinkEscapeIsRejected() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let ownerURL = root.appendingPathComponent("garments/\(owner.directoryName)")
        try FileManager.default.createSymbolicLink(
            at: ownerURL,
            withDestinationURL: FileManager.default.temporaryDirectory
        )
        let resource = try StorageResourceID(owner: owner, kind: .thumbnail)

        do {
            _ = try await storage.exists(resource)
            XCTFail("Expected a symbolic-link rejection.")
        } catch {
            XCTAssertEqual(error as? StorageError, .symbolicLinkNotAllowed)
        }
    }

    func testInitializationRejectsManagedTopLevelSymbolicLink() throws {
        let root = try makeRoot()
        let garments = root.appendingPathComponent("garments", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: garments,
            withDestinationURL: FileManager.default.temporaryDirectory
        )

        XCTAssertThrowsError(try makeStorage(root: root)) { error in
            XCTAssertEqual(error as? StorageError, .symbolicLinkNotAllowed)
        }
    }

    func testCacheManagementDoesNotAffectPersistentResources() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let key = UUID()
        let persistent = try StorageResourceID(
            owner: StorageOwner(kind: .person, id: UUID()),
            kind: .thumbnail
        )
        try await storage.write(Data([9]), to: persistent)
        try await storage.writeCache(Data([8]), namespace: "previews", key: key)

        let cached = try await storage.readCache(namespace: "previews", key: key)
        XCTAssertEqual(cached, Data([8]))
        try await storage.deleteCacheFile(namespace: "previews", key: key)

        let deletedCache = try await storage.readCache(namespace: "previews", key: key)
        let persistentData = try await storage.read(persistent)
        XCTAssertNil(deletedCache)
        XCTAssertEqual(persistentData, Data([9]))
    }

    private func directoryContents(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private func makeImageData(
        type: UTType,
        width: Int,
        height: Int,
        orientation: Int? = nil,
        color: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.2, 0.5, 0.8, 1)
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageValidationError.thumbnailEncodingFailed
        }
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ImageValidationError.thumbnailEncodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageValidationError.thumbnailEncodingFailed
        }
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageValidationError.thumbnailEncodingFailed
        }
        return data as Data
    }
}

private struct FailingThumbnailGenerator: ImageThumbnailGenerating {
    private let base = ImageIOThumbnailGenerator()

    func inspectImage(at sourceURL: URL) throws -> ImageMetadata {
        try base.inspectImage(at: sourceURL)
    }

    func makeThumbnail(at sourceURL: URL, configuration: ThumbnailConfiguration) throws -> Data {
        throw ImageValidationError.thumbnailEncodingFailed
    }
}
