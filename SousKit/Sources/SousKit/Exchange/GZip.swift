import Foundation

/// Just enough of gzip to read Paprika's recipe files.
///
/// A gzip file is a DEFLATE stream between a small header and an eight-byte
/// trailer, and the trailer records the uncompressed size — so the stream
/// can go through the same decoder the ZIP reader uses, with nothing added.
enum GZip {
    /// Whether the data begins with gzip's magic bytes.
    static func isCompressed(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let start = data.startIndex
        return data[start] == 0x1F && data[start + 1] == 0x8B
    }

    /// The decompressed bytes, or `nil` when the data is not gzip or is
    /// damaged.
    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        // Header: magic, method (8 = deflate), flags, mtime, extra flags, OS.
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            return nil
        }
        let flags = bytes[3]
        var offset = 10

        // Optional header fields, present in this order when their flag is set.
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT
            guard let end = bytes[min(offset, bytes.count)...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC

        let trailer = bytes.count - 8
        guard offset <= trailer else { return nil }
        // The size modulo 2³² — exact for anything the entry limit lets through.
        let size = Int(bytes[trailer + 4]) | Int(bytes[trailer + 5]) << 8
            | Int(bytes[trailer + 6]) << 16 | Int(bytes[trailer + 7]) << 24
        guard size <= ZIPArchive.entrySizeLimit else { return nil }

        return ZIPArchive.inflate(Data(bytes[offset..<trailer]), uncompressedSize: size)
    }
}
