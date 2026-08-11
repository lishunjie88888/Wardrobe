import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Wardrobe

final class Stage3ImageProcessingTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeStage3Tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return root
    }

    private func makeStorage(root: URL) throws -> StorageService {
        try StorageService(configuration: StorageConfiguration(rootURL: root))
    }

    private func storeOriginal(
        _ data: Data,
        format: SupportedImageFormat,
        owner: StorageOwner,
        storage: StorageService
    ) async throws -> StorageResourceID {
        let resource = try StorageResourceID(
            owner: owner,
            kind: .original(fileExtension: format.preferredFileExtension)
        )
        try await storage.write(data, to: resource)
        return resource
    }

    func testJPEGOrientationIsNormalizedAndOriginalIsUnchanged() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let sourceData = try makeImageData(type: .jpeg, width: 40, height: 80, orientation: 6)
        let original = try await storeOriginal(sourceData, format: .jpeg, owner: owner, storage: storage)

        let result = try await ImageProcessingService(storage: storage).process(
            originalResourceID: original,
            preset: .garment
        )

        let processed = try await storage.read(result.processedResourceID)
        let properties = try imageProperties(processed)
        XCTAssertGreaterThan(try integerProperty(kCGImagePropertyPixelWidth, in: properties),
                             try integerProperty(kCGImagePropertyPixelHeight, in: properties))
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(result.processed.orientation, .up)
        let storedOriginal = try await storage.read(original)
        XCTAssertEqual(storedOriginal, sourceData)
    }

    func testPNGInputProducesDecodablePNGAndJPEGResources() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .person, id: UUID())
        let original = try await storeOriginal(
            makeImageData(type: .png, width: 640, height: 960),
            format: .png,
            owner: owner,
            storage: storage
        )

        let result = try await ImageProcessingService(storage: storage).process(
            originalResourceID: original,
            preset: .person
        )

        let processedData = try await storage.read(result.processedResourceID)
        let thumbnailData = try await storage.read(result.thumbnailResourceID)
        XCTAssertEqual(try detectedType(processedData), UTType.png.identifier)
        XCTAssertEqual(try detectedType(thumbnailData), UTType.jpeg.identifier)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(try imageSource(processedData), 0, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(try imageSource(thumbnailData), 0, nil))
    }

    func testHEICInputWhenSystemFixtureIsAvailable() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        guard let sourceData = try? makeImageData(type: .heic, width: 320, height: 180) else {
            throw XCTSkip("The active macOS ImageIO runtime cannot encode the HEIC fixture.")
        }
        let owner = StorageOwner(kind: .garment, id: UUID())
        let original = try await storeOriginal(sourceData, format: .heic, owner: owner, storage: storage)

        let result = try await ImageProcessingService(storage: storage).process(
            originalResourceID: original,
            preset: .garment
        )

        let processedData = try await storage.read(result.processedResourceID)
        XCTAssertEqual(try detectedType(processedData), UTType.png.identifier)
        XCTAssertEqual(result.processed.pixelWidth, 320)
        XCTAssertEqual(result.processed.pixelHeight, 180)
    }

    func testPresetBoundsAndAspectRatioAreStable() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let original = try await storeOriginal(
            makeImageData(type: .jpeg, width: 5_000, height: 3_000),
            format: .jpeg,
            owner: owner,
            storage: storage
        )

        let result = try await ImageProcessingService(storage: storage).process(
            originalResourceID: original,
            preset: .garment
        )

        XCTAssertEqual(max(result.processed.pixelWidth, result.processed.pixelHeight), 2_048)
        XCTAssertLessThanOrEqual(max(result.thumbnailPixelWidth, result.thumbnailPixelHeight), 512)
        XCTAssertEqual(
            Double(result.processed.pixelWidth) / Double(result.processed.pixelHeight),
            5.0 / 3.0,
            accuracy: 0.002
        )
    }

    func testPersonPresetRetainsMoreDetailThanGarmentPreset() {
        XCTAssertEqual(ImageProcessingPreset.garment.options.processedMaxPixelSize, 2_048)
        XCTAssertEqual(ImageProcessingPreset.person.options.processedMaxPixelSize, 4_096)
        XCTAssertGreaterThan(
            ImageProcessingPreset.person.options.thumbnailJPEGQuality,
            ImageProcessingPreset.garment.options.thumbnailJPEGQuality
        )
        XCTAssertEqual(ImageProcessingPreset.garment.options.alphaPolicy, .preserve)
        XCTAssertEqual(ImageProcessingPreset.person.options.alphaPolicy, .flattenToWhite)
    }

    func testGarmentPreservesAlphaAndPersonFlattensAlpha() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let transparent = try makeImageData(
            type: .png,
            width: 32,
            height: 32,
            color: (0.8, 0.2, 0.4, 0.25)
        )
        let garmentOriginal = try await storeOriginal(
            transparent,
            format: .png,
            owner: StorageOwner(kind: .garment, id: UUID()),
            storage: storage
        )
        let personOriginal = try await storeOriginal(
            transparent,
            format: .png,
            owner: StorageOwner(kind: .person, id: UUID()),
            storage: storage
        )

        let service = ImageProcessingService(storage: storage)
        let garment = try await service.process(originalResourceID: garmentOriginal, preset: .garment)
        let person = try await service.process(originalResourceID: personOriginal, preset: .person)
        let garmentImage = try decodedImage(await storage.read(garment.processedResourceID))
        let personImage = try decodedImage(await storage.read(person.processedResourceID))

        XCTAssertTrue(garmentImage.alphaInfo == .premultipliedLast || garmentImage.alphaInfo == .last)
        XCTAssertTrue(personImage.alphaInfo == .noneSkipLast || personImage.alphaInfo == .none)
        XCTAssertEqual(garment.processed.alphaPolicy, .preserve)
        XCTAssertEqual(person.processed.alphaPolicy, .flattenToWhite)
    }

    func testProcessedImageUsesSRGBAndEmbedsPipelineVersion() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let original = try await storeOriginal(
            makeImageData(type: .png, width: 80, height: 60),
            format: .png,
            owner: StorageOwner(kind: .garment, id: UUID()),
            storage: storage
        )

        let result = try await ImageProcessingService(storage: storage).process(
            originalResourceID: original,
            preset: .garment
        )
        let processedData = try await storage.read(result.processedResourceID)
        let image = try decodedImage(processedData)
        let properties = try imageProperties(processedData)
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]

        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(result.processed.colorSpaceName, "sRGB")
        XCTAssertEqual(result.processed.pipelineVersion, ImageProcessingPipeline.version)
        XCTAssertEqual(png?[kCGImagePropertyPNGSoftware] as? String, "Wardrobe/\(ImageProcessingPipeline.version)")
    }

    func testExistingStage2ThumbnailIsReplacedOnlyWhenProcessedPublishes() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("incoming.png")
        try makeImageData(type: .png, width: 1_200, height: 800).write(to: source)
        let storage = try makeStorage(root: root)
        let imported = try await storage.importImage(
            from: source,
            for: StorageOwner(kind: .garment, id: UUID())
        )
        let priorThumbnail = try await storage.read(imported.thumbnail)

        let result = try await ImageProcessingService(storage: storage).process(
            originalResourceID: imported.original,
            preset: .garment
        )

        let processedExists = try await storage.exists(result.processedResourceID)
        let thumbnailExists = try await storage.exists(result.thumbnailResourceID)
        let newThumbnail = try await storage.read(result.thumbnailResourceID)
        let storedOriginal = try await storage.read(imported.original)
        XCTAssertTrue(processedExists)
        XCTAssertTrue(thumbnailExists)
        XCTAssertNotEqual(newThumbnail, priorThumbnail)
        XCTAssertEqual(storedOriginal, try Data(contentsOf: source))
    }

    func testNonImageInputFailsAndLeavesNoPublishedResource() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let original = try await storeOriginal(
            Data("not an image".utf8),
            format: .jpeg,
            owner: owner,
            storage: storage
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await ImageProcessingService(storage: storage).process(
                originalResourceID: original,
                preset: .garment
            )
        }

        let processedExists = try await storage.exists(StorageResourceID(owner: owner, kind: .processed))
        XCTAssertFalse(processedExists)
        XCTAssertEqual(try directoryContents(root.appendingPathComponent("staging")).count, 0)
    }

    func testPixelLimitIsEnforcedBeforeDecode() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .person, id: UUID())
        let original = try await storeOriginal(
            try makeOversizedPNG(width: 10_001, height: 10_000),
            format: .png,
            owner: owner,
            storage: storage
        )

        do {
            _ = try await ImageProcessingService(storage: storage).process(
                originalResourceID: original,
                preset: .person
            )
            XCTFail("Expected the pixel limit to reject the source.")
        } catch {
            XCTAssertEqual(
                error as? ImageValidationError,
                .pixelCountTooLarge(maximumPixels: ImageIOThumbnailGenerator.maximumPixelCount)
            )
        }

        let processedExists = try await storage.exists(StorageResourceID(owner: owner, kind: .processed))
        XCTAssertFalse(processedExists)
        XCTAssertEqual(try directoryContents(root.appendingPathComponent("staging")).count, 0)
    }

    func testCancellationStopsProcessingWithoutPublishingPartialResource() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("incoming.png")
        try makeImageData(type: .png, width: 1_600, height: 1_200).write(to: source)
        let storage = try makeStorage(root: root)
        let imported = try await storage.importImage(
            from: source,
            for: StorageOwner(kind: .garment, id: UUID())
        )
        let service = ImageProcessingService(
            storage: storage,
            backgroundRemovalProvider: CancellableBackgroundRemovalProvider()
        )
        let task = Task {
            try await service.process(originalResourceID: imported.original, preset: .garment)
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected: cancellation remains distinct from processing failure.
        }

        let processed = try StorageResourceID(owner: imported.original.owner, kind: .processed)
        let processedExists = try await storage.exists(processed)
        let thumbnailExists = try await storage.exists(imported.thumbnail)
        XCTAssertFalse(processedExists)
        XCTAssertTrue(thumbnailExists)
        XCTAssertEqual(try directoryContents(root.appendingPathComponent("staging")).count, 0)
    }

    func testSecondProcessingRefusesToOverwritePublishedProcessedImage() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let originalData = try makeImageData(type: .jpeg, width: 200, height: 100)
        let original = try await storeOriginal(originalData, format: .jpeg, owner: owner, storage: storage)
        let service = ImageProcessingService(storage: storage)
        let first = try await service.process(originalResourceID: original, preset: .garment)
        let firstProcessed = try await storage.read(first.processedResourceID)

        do {
            _ = try await service.process(originalResourceID: original, preset: .garment)
            XCTFail("Expected immutable processed publication.")
        } catch {
            XCTAssertEqual(error as? StorageError, .resourceAlreadyExists(first.processedResourceID))
        }

        let retainedProcessed = try await storage.read(first.processedResourceID)
        let retainedOriginal = try await storage.read(original)
        XCTAssertEqual(retainedProcessed, firstProcessed)
        XCTAssertEqual(retainedOriginal, originalData)
        XCTAssertEqual(try directoryContents(root.appendingPathComponent("staging")).count, 0)
    }

    func testResourceIDsRemainReadableAfterStorageAndServiceRebuild() async throws {
        let root = try makeRoot()
        let storage = try makeStorage(root: root)
        let original = try await storeOriginal(
            makeImageData(type: .png, width: 300, height: 500),
            format: .png,
            owner: StorageOwner(kind: .person, id: UUID()),
            storage: storage
        )
        let result = try await ImageProcessingService(storage: storage).process(
            originalResourceID: original,
            preset: .person
        )

        let rebuiltStorage = try makeStorage(root: root)
        let rebuiltService: any ImageProcessingServing = ImageProcessingService(storage: rebuiltStorage)
        _ = rebuiltService
        let rebuiltProcessed = try await rebuiltStorage.read(result.processedResourceID)
        let rebuiltThumbnail = try await rebuiltStorage.read(result.thumbnailResourceID)
        XCTAssertNotNil(try decodedImage(rebuiltProcessed))
        XCTAssertNotNil(try decodedImage(rebuiltThumbnail))
        XCTAssertEqual(
            try StorageResourceID(rawValue: result.processedResourceID.rawValue),
            result.processedResourceID
        )
    }

    func testDisabledBackgroundRemovalIsDeterministicNoOp() async throws {
        let image = try makeCGImage(width: 8, height: 6, color: (0.1, 0.2, 0.3, 1))
        let provider = DisabledBackgroundRemovalProvider()
        XCTAssertEqual(provider.identifier, "disabled")
        let result = try await provider.removeBackground(from: image)
        XCTAssertTrue(result === image)
    }

    private func imageSource(_ data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary))
    }

    private func imageProperties(_ data: Data) throws -> [CFString: Any] {
        let source = try imageSource(data)
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func integerProperty(_ key: CFString, in properties: [CFString: Any]) throws -> Int {
        try XCTUnwrap(properties[key] as? Int)
    }

    private func detectedType(_ data: Data) throws -> String {
        try XCTUnwrap(CGImageSourceGetType(try imageSource(data)) as String?)
    }

    private func decodedImage(_ data: Data) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(try imageSource(data), 0, nil))
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
        let image = try makeCGImage(width: width, height: height, color: color)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessingError.processedEncodingFailed
        }
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.processedEncodingFailed
        }
        return data as Data
    }

    private func makeCGImage(
        width: Int,
        height: Int,
        color: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ImageProcessingError.colorSpaceConversionFailed
        }
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeOversizedPNG(width: UInt32, height: UInt32) throws -> Data {
        let bytesPerRow = 1 + (Int(width) + 7) / 8
        let raw = Data(repeating: 0, count: bytesPerRow * Int(height))
        var compressed = Data(count: raw.count)
        let compressedSize = compressed.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard compressedSize > 0 else { throw ImageProcessingError.processedEncodingFailed }
        compressed.removeSubrange(compressedSize ..< compressed.count)

        var header = Data()
        header.append(contentsOf: width.bigEndianBytes)
        header.append(contentsOf: height.bigEndianBytes)
        header.append(contentsOf: [1, 0, 0, 0, 0])
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        png.append(pngChunk(type: "IHDR", payload: header))
        png.append(pngChunk(type: "IDAT", payload: compressed))
        png.append(pngChunk(type: "IEND", payload: Data()))
        return png
    }

    private func pngChunk(type: String, payload: Data) -> Data {
        let typeData = Data(type.utf8)
        var output = Data()
        output.append(contentsOf: UInt32(payload.count).bigEndianBytes)
        output.append(typeData)
        output.append(payload)
        output.append(contentsOf: crc32(typeData + payload).bigEndianBytes)
        return output
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

private struct CancellableBackgroundRemovalProvider: BackgroundRemovalProviding {
    let identifier = "test-cancellable"

    func removeBackground(from image: CGImage) async throws -> CGImage {
        for _ in 0 ..< 200 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        return image
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        var value = bigEndian
        return Swift.withUnsafeBytes(of: &value) { Array($0) }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected an error.", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
