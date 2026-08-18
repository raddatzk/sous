import Compression
import Foundation

/// Just enough of the ZIP format to read an exported recipe archive.
///
/// Written out rather than pulled in as a dependency: reading needs the
/// central directory, stored and deflated entries, and the Zip64 fields —
/// nothing else. Apple ships no public API for unzipping on either platform,
/// so this is the alternative to a third-party package for about a hundred
/// and fifty lines.
///
/// Zip64 is not optional here even though a recipe library is nowhere near
/// four gigabytes: Mela's export writes `0xFFFFFFFF` into the classic size
/// fields and puts the real numbers in the Zip64 extra field regardless of
/// how small the archive is. A reader that treats that marker as "too large
/// to handle" silently returns an empty library.
enum ZIPArchive {
    struct Entry: Sendable, Hashable {
        let name: String
        let data: Data
    }

    /// A single entry larger than this is refused rather than decompressed.
    /// A recipe archive is text and photos; anything at this size is either
    /// broken or hostile.
    static let entrySizeLimit = 256 * 1024 * 1024

    enum Failure: Error {
        case notAnArchive
    }

    /// Whether the data begins like a ZIP file.
    static func looksLikeArchive(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let start = data.startIndex
        return data[start] == 0x50 && data[start + 1] == 0x4B
            && (data[start + 2] == 0x03 || data[start + 2] == 0x05 || data[start + 2] == 0x01)
    }

    /// Every file entry, in the order the central directory lists them.
    ///
    /// Entries that cannot be decompressed are left out rather than throwing:
    /// one damaged photo should not cost the whole library.
    static func entries(in data: Data) throws -> [Entry] {
        guard let directoryStart = centralDirectoryOffset(in: data) else {
            throw Failure.notAnArchive
        }

        var entries: [Entry] = []
        var offset = directoryStart
        while let signature = uint32(data, offset), signature == 0x0201_4B50 {
            guard
                let method = uint16(data, offset + 10),
                let compressedSize = uint32(data, offset + 20),
                let uncompressedSize = uint32(data, offset + 24),
                let nameLength = uint16(data, offset + 28),
                let extraLength = uint16(data, offset + 30),
                let commentLength = uint16(data, offset + 32),
                let localOffset = uint32(data, offset + 42),
                let name = string(data, offset + 46, count: Int(nameLength))
            else { break }

            // Anything marked 0xFFFFFFFF has its real value in the Zip64
            // extra field, which lists only the fields that overflowed, in a
            // fixed order.
            let sizes = zip64Sizes(
                in: data,
                at: offset + 46 + Int(nameLength),
                length: Int(extraLength),
                compressed: compressedSize,
                uncompressed: uncompressedSize,
                localOffset: localOffset
            )

            if !name.hasSuffix("/"), sizes.uncompressed <= entrySizeLimit,
               let content = content(
                   in: data,
                   localHeaderOffset: sizes.localOffset,
                   method: method,
                   compressedSize: sizes.compressed,
                   uncompressedSize: sizes.uncompressed
               ) {
                entries.append(Entry(name: name, data: content))
            }

            offset += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return entries
    }

    /// The true sizes and offset of an entry, reading the Zip64 extra field
    /// where the 32-bit fields say the value did not fit.
    private static func zip64Sizes(
        in data: Data,
        at start: Int,
        length: Int,
        compressed: UInt32,
        uncompressed: UInt32,
        localOffset: UInt32
    ) -> (compressed: Int, uncompressed: Int, localOffset: Int) {
        var result = (
            compressed: Int(compressed),
            uncompressed: Int(uncompressed),
            localOffset: Int(localOffset)
        )
        guard compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF
        else { return result }

        // The extra area is a sequence of (id, size, payload) blocks.
        var cursor = start
        let end = start + length
        while cursor + 4 <= end {
            guard let id = uint16(data, cursor), let size = uint16(data, cursor + 2) else { break }
            let payload = cursor + 4
            if id == 0x0001 {
                var field = payload
                // Order is fixed — uncompressed, compressed, offset — and a
                // value is present only if its 32-bit field overflowed.
                if uncompressed == 0xFFFF_FFFF, let value = uint64(data, field) {
                    result.uncompressed = Int(clamping: value)
                    field += 8
                }
                if compressed == 0xFFFF_FFFF, let value = uint64(data, field) {
                    result.compressed = Int(clamping: value)
                    field += 8
                }
                if localOffset == 0xFFFF_FFFF, let value = uint64(data, field) {
                    result.localOffset = Int(clamping: value)
                }
                break
            }
            cursor = payload + Int(size)
        }
        return result
    }

    /// The bytes of one entry, following its local header to find where the
    /// data actually starts — the header carries its own name and extra
    /// fields, whose lengths differ from the central directory's.
    private static func content(
        in data: Data,
        localHeaderOffset: Int,
        method: UInt16,
        compressedSize: Int,
        uncompressedSize: Int
    ) -> Data? {
        guard uint32(data, localHeaderOffset) == 0x0403_4B50,
              let nameLength = uint16(data, localHeaderOffset + 26),
              let extraLength = uint16(data, localHeaderOffset + 28)
        else { return nil }

        let start = localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        let end = start + compressedSize
        guard start >= 0, end <= data.count else { return nil }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))

        switch method {
        case 0: return payload
        case 8: return inflate(payload, uncompressedSize: uncompressedSize)
        default: return nil
        }
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` decodes — the zlib
    /// wrapper a ZIP entry does not have.
    private static func inflate(_ data: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        guard !data.isEmpty else { return nil }

        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let target = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let origin = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    target, uncompressedSize,
                    origin, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == uncompressedSize ? output : nil
    }

    /// Finds the end-of-central-directory record, which is at the end of the
    /// file behind a comment of unknown length — hence the backwards scan.
    ///
    /// An archive past four gigabytes keeps its real offset in the Zip64
    /// record the locator points at, and leaves `0xFFFFFFFF` here.
    private static func centralDirectoryOffset(in data: Data) -> Int? {
        let maximumComment = 0xFFFF
        let lowest = max(0, data.count - maximumComment - 22)
        var offset = data.count - 22
        while offset >= lowest {
            if uint32(data, offset) == 0x0605_4B50 {
                guard let start = uint32(data, offset + 16) else { return nil }
                if start == 0xFFFF_FFFF { return zip64CentralDirectoryOffset(in: data) }
                return Int(start) <= data.count ? Int(start) : nil
            }
            offset -= 1
        }
        return nil
    }

    private static func zip64CentralDirectoryOffset(in data: Data) -> Int? {
        // The locator sits just before the classic record and points at the
        // Zip64 end-of-central-directory record.
        let lowest = max(0, data.count - 0xFFFF - 40)
        var offset = data.count - 20
        while offset >= lowest {
            if uint32(data, offset) == 0x0706_4B50 {
                guard let recordOffset = uint64(data, offset + 8),
                      uint32(data, Int(recordOffset)) == 0x0606_4B50,
                      let start = uint64(data, Int(recordOffset) + 48),
                      start <= UInt64(data.count)
                else { return nil }
                return Int(start)
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Little-endian reads

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let index = data.startIndex + offset
        return UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let index = data.startIndex + offset
        return UInt32(data[index]) | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }

    private static func uint64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        guard let low = uint32(data, offset), let high = uint32(data, offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    /// Entry names are UTF-8 when the encoding flag is set and CP437
    /// otherwise; the archives this reads come from Apple platforms, where
    /// both amount to UTF-8 with an ISO-8859-1 fallback for old writers.
    private static func string(_ data: Data, _ offset: Int, count: Int) -> String? {
        guard offset >= 0, offset + count <= data.count else { return nil }
        let index = data.startIndex + offset
        let bytes = data.subdata(in: index..<(index + count))
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
    }
}
