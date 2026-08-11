import CoreGraphics
import Foundation

enum ImageProcessingPipeline {
    static let version = "wardrobe-image-v1"
}

enum ProcessedImageFormat: String, Sendable {
    case png

    var mimeType: String { "image/png" }
}

enum ImageAlphaPolicy: Equatable, Sendable {
    case preserve
    case flattenToWhite
}

enum ProcessedImageOrientation: String, Sendable {
    case up
}

enum ImageProcessingPreset: String, CaseIterable, Sendable {
    case garment
    case person
    case generatedResult

    var options: ImageProcessingOptions {
        switch self {
        case .garment:
            ImageProcessingOptions(
                preset: self,
                processedMaxPixelSize: 2_048,
                thumbnailMaxPixelSize: 512,
                thumbnailJPEGQuality: 0.82,
                alphaPolicy: .preserve,
                usesBackgroundRemoval: true
            )
        case .person:
            ImageProcessingOptions(
                preset: self,
                processedMaxPixelSize: 4_096,
                thumbnailMaxPixelSize: 512,
                thumbnailJPEGQuality: 0.86,
                alphaPolicy: .flattenToWhite,
                usesBackgroundRemoval: false
            )
        case .generatedResult:
            ImageProcessingOptions(
                preset: self,
                processedMaxPixelSize: 3_072,
                thumbnailMaxPixelSize: 512,
                thumbnailJPEGQuality: 0.84,
                alphaPolicy: .preserve,
                usesBackgroundRemoval: false
            )
        }
    }
}

struct ImageProcessingOptions: Equatable, Sendable {
    let preset: ImageProcessingPreset
    let processedMaxPixelSize: Int
    let thumbnailMaxPixelSize: Int
    let thumbnailJPEGQuality: Double
    let alphaPolicy: ImageAlphaPolicy
    let usesBackgroundRemoval: Bool

    var pipelineVersion: String { ImageProcessingPipeline.version }
}

struct ProcessedImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let format: ProcessedImageFormat
    let colorSpaceName: String
    let alphaPolicy: ImageAlphaPolicy
    let orientation: ProcessedImageOrientation
    let pipelineVersion: String
}

struct ImageProcessingResult: Equatable, Sendable {
    let processedResourceID: StorageResourceID
    let thumbnailResourceID: StorageResourceID
    let processed: ProcessedImageMetadata
    let thumbnailPixelWidth: Int
    let thumbnailPixelHeight: Int
}

enum ImageProcessingError: Error, Equatable, LocalizedError {
    case invalidOriginalResource
    case invalidOptions
    case sourceUnavailable
    case decodingFailed
    case colorSpaceConversionFailed
    case processedEncodingFailed
    case thumbnailEncodingFailed
    case outputValidationFailed
    case backgroundRemovalFailed

    var errorDescription: String? {
        switch self {
        case .invalidOriginalResource: "Image processing requires a garment or person original resource."
        case .invalidOptions: "The image processing options are invalid."
        case .sourceUnavailable: "The controlled source image is unavailable."
        case .decodingFailed: "The source image could not be decoded."
        case .colorSpaceConversionFailed: "The image could not be normalized to sRGB."
        case .processedEncodingFailed: "The processed PNG could not be encoded."
        case .thumbnailEncodingFailed: "The thumbnail JPEG could not be encoded."
        case .outputValidationFailed: "The image processing output did not pass validation."
        case .backgroundRemovalFailed: "Background removal failed."
        }
    }
}

protocol ImageProcessingServing: Sendable {
    func process(
        originalResourceID: StorageResourceID,
        preset: ImageProcessingPreset
    ) async throws -> ImageProcessingResult

    func process(
        originalResourceID: StorageResourceID,
        options: ImageProcessingOptions
    ) async throws -> ImageProcessingResult
}

protocol BackgroundRemovalProviding: Sendable {
    var identifier: String { get }
    func removeBackground(from image: CGImage) async throws -> CGImage
}

struct DisabledBackgroundRemovalProvider: BackgroundRemovalProviding {
    let identifier = "disabled"

    func removeBackground(from image: CGImage) async throws -> CGImage { image }
}

struct ImageProcessingWorkspace: Sendable {
    let operationID: UUID
    let originalResourceID: StorageResourceID
    let inputURL: URL
    let processedOutputURL: URL
    let thumbnailOutputURL: URL
}

struct PublishedImageProcessingResources: Equatable, Sendable {
    let processed: StorageResourceID
    let thumbnail: StorageResourceID
}

protocol ImageProcessingStorageServing: Sendable {
    func beginImageProcessing(
        originalResourceID: StorageResourceID
    ) async throws -> ImageProcessingWorkspace

    func publishImageProcessingOutputs(
        from workspace: ImageProcessingWorkspace
    ) async throws -> PublishedImageProcessingResources

    func discardImageProcessingWorkspace(_ operationID: UUID) async throws
}
