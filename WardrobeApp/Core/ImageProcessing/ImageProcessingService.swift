import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageProcessingService: ImageProcessingServing, Sendable {
    private let storage: any ImageProcessingStorageServing
    private let backgroundRemovalProvider: any BackgroundRemovalProviding

    init(
        storage: any ImageProcessingStorageServing,
        backgroundRemovalProvider: any BackgroundRemovalProviding = DisabledBackgroundRemovalProvider()
    ) {
        self.storage = storage
        self.backgroundRemovalProvider = backgroundRemovalProvider
    }

    func process(
        originalResourceID: StorageResourceID,
        preset: ImageProcessingPreset
    ) async throws -> ImageProcessingResult {
        try await process(originalResourceID: originalResourceID, options: preset.options)
    }

    func process(
        originalResourceID: StorageResourceID,
        options: ImageProcessingOptions
    ) async throws -> ImageProcessingResult {
        try Task.checkCancellation()
        try Self.validate(options)
        let workspace = try await storage.beginImageProcessing(originalResourceID: originalResourceID)

        do {
            try Task.checkCancellation()
            let provider = backgroundRemovalProvider
            let worker = Task.detached(priority: .userInitiated) {
                try await ImageIOProcessingWorker.process(
                    workspace: workspace,
                    options: options,
                    backgroundRemovalProvider: provider
                )
            }
            let metadata = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let resources = try await storage.publishImageProcessingOutputs(from: workspace)
            return ImageProcessingResult(
                processedResourceID: resources.processed,
                thumbnailResourceID: resources.thumbnail,
                processed: metadata.processed,
                thumbnailPixelWidth: metadata.thumbnailWidth,
                thumbnailPixelHeight: metadata.thumbnailHeight
            )
        } catch is CancellationError {
            try? await storage.discardImageProcessingWorkspace(workspace.operationID)
            throw CancellationError()
        } catch {
            try? await storage.discardImageProcessingWorkspace(workspace.operationID)
            throw error
        }
    }

    private static func validate(_ options: ImageProcessingOptions) throws {
        guard options.processedMaxPixelSize > 0,
              options.thumbnailMaxPixelSize > 0,
              options.thumbnailMaxPixelSize <= options.processedMaxPixelSize,
              (0 ... 1).contains(options.thumbnailJPEGQuality)
        else {
            throw ImageProcessingError.invalidOptions
        }
    }
}

private enum ImageIOProcessingWorker {
    struct OutputMetadata: Sendable {
        let processed: ProcessedImageMetadata
        let thumbnailWidth: Int
        let thumbnailHeight: Int
    }

    static func process(
        workspace: ImageProcessingWorkspace,
        options: ImageProcessingOptions,
        backgroundRemovalProvider: any BackgroundRemovalProviding
    ) async throws -> OutputMetadata {
        try Task.checkCancellation()
        _ = try ImageIOThumbnailGenerator().inspectImage(at: workspace.inputURL)
        guard let source = CGImageSourceCreateWithURL(workspace.inputURL as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), CGImageSourceGetCount(source) > 0 else {
            throw ImageProcessingError.sourceUnavailable
        }

        guard let downsampled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: options.processedMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary) else {
            throw ImageProcessingError.decodingFailed
        }
        try Task.checkCancellation()

        let backgroundProcessed: CGImage
        if options.usesBackgroundRemoval {
            do {
                backgroundProcessed = try await backgroundRemovalProvider.removeBackground(from: downsampled)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ImageProcessingError.backgroundRemovalFailed
            }
        } else {
            backgroundProcessed = downsampled
        }
        try Task.checkCancellation()

        guard let normalized = normalizeToSRGB(backgroundProcessed, alphaPolicy: options.alphaPolicy) else {
            throw ImageProcessingError.colorSpaceConversionFailed
        }
        try Task.checkCancellation()

        try encodeProcessedPNG(
            normalized,
            to: workspace.processedOutputURL,
            pipelineVersion: options.pipelineVersion
        )
        try Task.checkCancellation()

        guard let thumbnail = resize(
            normalized,
            maxPixelSize: options.thumbnailMaxPixelSize,
            alphaPolicy: .flattenToWhite
        ) else {
            throw ImageProcessingError.thumbnailEncodingFailed
        }
        try encodeThumbnailJPEG(
            thumbnail,
            to: workspace.thumbnailOutputURL,
            quality: options.thumbnailJPEGQuality
        )
        try Task.checkCancellation()

        return OutputMetadata(
            processed: ProcessedImageMetadata(
                pixelWidth: normalized.width,
                pixelHeight: normalized.height,
                format: .png,
                colorSpaceName: "sRGB",
                alphaPolicy: options.alphaPolicy,
                orientation: .up,
                pipelineVersion: options.pipelineVersion
            ),
            thumbnailWidth: thumbnail.width,
            thumbnailHeight: thumbnail.height
        )
    }

    private static func normalizeToSRGB(
        _ image: CGImage,
        alphaPolicy: ImageAlphaPolicy
    ) -> CGImage? {
        draw(image, width: image.width, height: image.height, alphaPolicy: alphaPolicy)
    }

    private static func resize(
        _ image: CGImage,
        maxPixelSize: Int,
        alphaPolicy: ImageAlphaPolicy
    ) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else {
            return draw(image, width: image.width, height: image.height, alphaPolicy: alphaPolicy)
        }
        let scale = CGFloat(maxPixelSize) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        return draw(image, width: width, height: height, alphaPolicy: alphaPolicy)
    }

    private static func draw(
        _ image: CGImage,
        width: Int,
        height: Int,
        alphaPolicy: ImageAlphaPolicy
    ) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let alphaInfo: CGImageAlphaInfo = alphaPolicy == .preserve ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | alphaInfo.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        if alphaPolicy == .flattenToWhite {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodeProcessedPNG(
        _ image: CGImage,
        to url: URL,
        pipelineVersion: String
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessingError.processedEncodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue,
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGSoftware: "Wardrobe/\(pipelineVersion)",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.processedEncodingFailed
        }
    }

    private static func encodeThumbnailJPEG(
        _ image: CGImage,
        to url: URL,
        quality: Double
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessingError.thumbnailEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.thumbnailEncodingFailed
        }
    }
}
