import CryptoKit
import Foundation

enum BackupJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func deterministicData<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }
}

enum BackupChecksum {
    static let chunkSize = 1_048_576

    /// Streams a file in chunks and returns its byte count and SHA-256 digest.
    /// Never loads the whole file into memory.
    static func digest(of url: URL, fileManager: FileManager = .default) throws -> BackupFileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            total += Int64(data.count)
        }
        return BackupFileDigest(byteCount: total, sha256: hasher.finalize().hexString)
    }

    /// Copies a source file to a destination while computing its digest in one
    /// streaming pass. Creates intermediate directories as needed.
    static func copyAndDigest(from sourceURL: URL, to destinationURL: URL) throws -> BackupFileDigest {
        try Task.checkCancellation()
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? source.close()
            try? destination.close()
        }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try source.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try destination.write(contentsOf: data)
            hasher.update(data: data)
            total += Int64(data.count)
        }
        try destination.synchronize()
        return BackupFileDigest(byteCount: total, sha256: hasher.finalize().hexString)
    }

    static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum BackupSafeMath {
    /// Saturating addition that never overflows, so hostile manifests cannot
    /// corrupt capacity calculations.
    static func add(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : result
    }

    static func multiply(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        return overflow ? Int64.max : result
    }

    static func scaled(_ value: Int64, percent: Int) -> Int64 {
        guard percent > 0 else { return 0 }
        return multiply(value, Int64(percent)) / 100
    }
}
