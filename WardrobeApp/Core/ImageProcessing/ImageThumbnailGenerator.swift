import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageMetadata: Equatable, Sendable {
    let format: SupportedImageFormat
    let pixelWidth: Int
    let pixelHeight: Int
    let fileSize: Int64
}

enum SupportedImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case png
    case heic
    case heif

    var preferredFileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .heif: "heif"
        }
    }

    var mimeType: String {
        switch self {
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .heic: "image/heic"
        case .heif: "image/heif"
        }
    }

    init?(typeIdentifier: String) {
        guard let type = UTType(typeIdentifier) else { return nil }
        if type.conforms(to: .jpeg) { self = .jpeg }
        else if type.conforms(to: .png) { self = .png }
        else if type.conforms(to: .heic) { self = .heic }
        else if type.conforms(to: .heif) { self = .heif }
        else { return nil }
    }
}

struct ThumbnailConfiguration: Equatable, Sendable {
    static let wardrobeDefault = ThumbnailConfiguration(maxPixelSize: 512, jpegQuality: 0.82)

    let maxPixelSize: Int
    let jpegQuality: Double
}

enum ImageValidationError: Error, Equatable, LocalizedError {
    case fileMissing
    case fileTooLarge(maximumBytes: Int64)
    case unreadableImage
    case unsupportedFormat
    case invalidDimensions
    case pixelCountTooLarge(maximumPixels: Int64)
    case thumbnailEncodingFailed

    var errorDescription: String? {
        switch self {
        case .fileMissing: "The image file does not exist."
        case let .fileTooLarge(maximumBytes): "The image exceeds the \(maximumBytes)-byte import limit."
        case .unreadableImage: "The file is not a decodable image."
        case .unsupportedFormat: "The image format is not supported."
        case .invalidDimensions: "The image has invalid pixel dimensions."
        case let .pixelCountTooLarge(maximumPixels): "The image exceeds the \(maximumPixels)-pixel import limit."
        case .thumbnailEncodingFailed: "The thumbnail could not be encoded."
        }
    }
}

protocol ImageThumbnailGenerating: Sendable {
    func inspectImage(at sourceURL: URL) throws -> ImageMetadata
    func makeThumbnail(at sourceURL: URL, configuration: ThumbnailConfiguration) throws -> Data
}

struct ImageIOThumbnailGenerator: ImageThumbnailGenerating {
    static let maximumFileSize: Int64 = 100 * 1_024 * 1_024
    static let maximumPixelCount: Int64 = 100_000_000

    func inspectImage(at sourceURL: URL) throws -> ImageMetadata {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImageValidationError.fileMissing }
        let fileSize = Int64(values.fileSize ?? 0)
        guard fileSize <= Self.maximumFileSize else {
            throw ImageValidationError.fileTooLarge(maximumBytes: Self.maximumFileSize)
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), CGImageSourceGetCount(source) > 0 else {
            throw ImageValidationError.unreadableImage
        }
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let format = SupportedImageFormat(typeIdentifier: typeIdentifier)
        else {
            throw ImageValidationError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            throw ImageValidationError.invalidDimensions
        }
        let (pixelCount, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !overflow, pixelCount <= Self.maximumPixelCount else {
            throw ImageValidationError.pixelCountTooLarge(maximumPixels: Self.maximumPixelCount)
        }
        return ImageMetadata(format: format, pixelWidth: width, pixelHeight: height, fileSize: fileSize)
    }

    func makeThumbnail(at sourceURL: URL, configuration: ThumbnailConfiguration) throws -> Data {
        guard configuration.maxPixelSize > 0,
              (0 ... 1).contains(configuration.jpegQuality),
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: configuration.maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: false,
              ] as CFDictionary)
        else {
            throw ImageValidationError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageValidationError.thumbnailEncodingFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: configuration.jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageValidationError.thumbnailEncodingFailed
        }
        return output as Data
    }
}
