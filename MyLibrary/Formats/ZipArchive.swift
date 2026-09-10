import Foundation
import Compression

/// Minimal, dependency-free reader for the ZIP container used by EPUB (and CBZ).
///
/// Only the two compression methods the ZIP spec requires are supported: `store`
/// and `deflate`. Deflate is handed to Apple's Compression framework
/// (`COMPRESSION_ZLIB` is raw DEFLATE, which is exactly what ZIP stores), so the
/// app ships no third-party archive code.
struct ZipEntry {
    var path: String
    var compressionMethod: UInt16
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
    var isDirectory: Bool { path.hasSuffix("/") }
}

final class ZipArchive {
    private let data: Data
    private(set) var entries: [ZipEntry] = []
    private var index: [String: Int] = [:]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.data = data
        guard parseCentralDirectory() else { return nil }
    }

    // MARK: - Byte access

    private var count: Int { data.count }

    private func byte(_ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    private func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(byte(offset)) | (UInt16(byte(offset + 1)) << 8)
    }

    private func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(byte(offset + i)) << (8 * UInt32(i)) }
        return value
    }

    private func u64(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(byte(offset + i)) << (8 * UInt64(i)) }
        return value
    }

    private func string(_ offset: Int, length: Int) -> String? {
        guard length >= 0, offset >= 0, offset + length <= count else { return nil }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
        return String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1)
    }

    // MARK: - Central directory

    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let eocd64LocatorSignature: UInt32 = 0x0706_4b50
    private static let eocd64Signature: UInt32 = 0x0606_4b50
    private static let centralFileSignature: UInt32 = 0x0201_4b50
    private static let localFileSignature: UInt32 = 0x0403_4b50

    private func parseCentralDirectory() -> Bool {
        guard let eocd = findEndOfCentralDirectory() else { return false }
        guard var entryCount = u16(eocd + 10).map(Int.init),
              var directoryOffset = u32(eocd + 16).map(Int.init) else { return false }

        // ZIP64: the 32-bit fields saturate and the real values live in the
        // ZIP64 end-of-central-directory record.
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            if let locator = findZip64Locator(before: eocd),
               let recordOffset = u64(locator + 8).map(Int.init),
               u32(recordOffset) == Self.eocd64Signature,
               let count64 = u64(recordOffset + 32).map(Int.init),
               let offset64 = u64(recordOffset + 48).map(Int.init) {
                entryCount = count64
                directoryOffset = offset64
            }
        }

        var offset = directoryOffset
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard u32(offset) == Self.centralFileSignature,
                  let method = u16(offset + 10),
                  let compressed = u32(offset + 20),
                  let uncompressed = u32(offset + 24),
                  let nameLength = u16(offset + 28).map(Int.init),
                  let extraLength = u16(offset + 30).map(Int.init),
                  let commentLength = u16(offset + 32).map(Int.init),
                  let localOffset = u32(offset + 42),
                  let name = string(offset + 46, length: nameLength) else { return !entries.isEmpty }

            var entry = ZipEntry(path: name,
                                 compressionMethod: method,
                                 compressedSize: Int(compressed),
                                 uncompressedSize: Int(uncompressed),
                                 localHeaderOffset: Int(localOffset))

            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                applyZip64Extra(at: offset + 46 + nameLength,
                                length: extraLength,
                                entry: &entry,
                                uncompressedSaturated: uncompressed == 0xFFFF_FFFF,
                                compressedSaturated: compressed == 0xFFFF_FFFF,
                                offsetSaturated: localOffset == 0xFFFF_FFFF)
            }

            if !entry.isDirectory {
                index[entry.path] = entries.count
                entries.append(entry)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        return true
    }

    private func applyZip64Extra(at offset: Int, length: Int, entry: inout ZipEntry,
                                 uncompressedSaturated: Bool,
                                 compressedSaturated: Bool,
                                 offsetSaturated: Bool) {
        var cursor = offset
        let end = offset + length
        while cursor + 4 <= end {
            guard let headerID = u16(cursor), let size = u16(cursor + 2).map(Int.init) else { return }
            if headerID == 0x0001 {
                var field = cursor + 4
                if uncompressedSaturated, let value = u64(field) {
                    entry.uncompressedSize = Int(value); field += 8
                }
                if compressedSaturated, let value = u64(field) {
                    entry.compressedSize = Int(value); field += 8
                }
                if offsetSaturated, let value = u64(field) {
                    entry.localHeaderOffset = Int(value)
                }
                return
            }
            cursor += 4 + size
        }
    }

    private func findEndOfCentralDirectory() -> Int? {
        // The record is at most 22 bytes plus a 64 KB comment.
        let minimum = max(0, count - (22 + 0xFFFF))
        var offset = count - 22
        while offset >= minimum {
            if u32(offset) == Self.eocdSignature { return offset }
            offset -= 1
        }
        return nil
    }

    private func findZip64Locator(before eocd: Int) -> Int? {
        let offset = eocd - 20
        guard offset >= 0, u32(offset) == Self.eocd64LocatorSignature else { return nil }
        return offset
    }

    // MARK: - Reading

    func contains(_ path: String) -> Bool { index[path] != nil }

    func data(for path: String) -> Data? {
        guard let position = index[path] else { return nil }
        return data(for: entries[position])
    }

    func data(for entry: ZipEntry) -> Data? {
        // The local header repeats the name/extra lengths; the payload follows it.
        let header = entry.localHeaderOffset
        guard u32(header) == Self.localFileSignature,
              let nameLength = u16(header + 26).map(Int.init),
              let extraLength = u16(header + 28).map(Int.init) else { return nil }

        let start = header + 30 + nameLength + extraLength
        guard start >= 0, start + entry.compressedSize <= count else { return nil }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))

        switch entry.compressionMethod {
        case 0: return payload
        case 8: return Self.inflate(payload, capacity: entry.uncompressedSize)
        default: return nil
        }
    }

    func string(for path: String) -> String? {
        guard let data = data(for: path) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Raw DEFLATE decompression. `capacity` comes from the central directory,
    /// so a single pass is enough for a well-formed archive.
    static func inflate(_ input: Data, capacity: Int) -> Data? {
        guard capacity > 0 else { return Data() }
        guard !input.isEmpty else { return nil }
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, capacity,
                                                 sourceBase, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return written == capacity ? output : Data(output.prefix(written))
    }

    // MARK: - Extraction

    /// Writes the whole archive into `directory`, ignoring entries that try to
    /// escape it via absolute or `..` paths.
    func extractAll(to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.standardizedFileURL.path

        for entry in entries {
            let relative = ZipArchive.sanitize(entry.path)
            guard !relative.isEmpty else { continue }
            let destination = directory.appendingPathComponent(relative).standardizedFileURL
            guard destination.path.hasPrefix(root) else { continue }

            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            guard let payload = data(for: entry) else { continue }
            try payload.write(to: destination, options: .atomic)
        }
    }

    private static func sanitize(_ path: String) -> String {
        path.split(separator: "/")
            .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
            .joined(separator: "/")
    }
}
