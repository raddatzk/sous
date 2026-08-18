import Foundation

/// Writes the kind of archive ``ZIPArchive`` reads.
///
/// Entries are stored rather than deflated: a recipe archive is mostly
/// photos, which are JPEG already, and compressing them again costs time to
/// save nothing. That also keeps the writer to one pass with no compression
/// state to carry.
enum ZIPWriter {
    struct Entry {
        let name: String
        let data: Data
        /// Shown by the Finder and every other archiver; without it an entry
        /// claims to be from 1980.
        var modified: Date = Date()
    }

    static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()
        var count: UInt16 = 0

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = UInt32(output.count)

            // Local file header, then the bytes themselves.
            output.append(uint32(0x0403_4B50))
            output.append(uint16(20))              // version needed
            output.append(uint16(1 << 11))         // names are UTF-8
            output.append(uint16(0))               // stored
            let stamp = dosTimestamp(entry.modified)
            output.append(uint16(stamp.time))
            output.append(uint16(stamp.date))
            output.append(uint32(crc))
            output.append(uint32(UInt32(entry.data.count)))
            output.append(uint32(UInt32(entry.data.count)))
            output.append(uint16(UInt16(name.count)))
            output.append(uint16(0))               // no extra field
            output.append(name)
            output.append(entry.data)

            directory.append(uint32(0x0201_4B50))
            directory.append(uint16(20))           // version made by
            directory.append(uint16(20))           // version needed
            directory.append(uint16(1 << 11))
            directory.append(uint16(0))            // stored
            directory.append(uint16(stamp.time))
            directory.append(uint16(stamp.date))
            directory.append(uint32(crc))
            directory.append(uint32(UInt32(entry.data.count)))
            directory.append(uint32(UInt32(entry.data.count)))
            directory.append(uint16(UInt16(name.count)))
            directory.append(uint16(0))            // extra
            directory.append(uint16(0))            // comment
            directory.append(uint16(0))            // disk
            directory.append(uint16(0))            // internal attributes
            directory.append(uint32(0))            // external attributes
            directory.append(uint32(offset))
            directory.append(name)

            count += 1
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(uint32(0x0605_4B50))
        output.append(uint16(0))                   // this disk
        output.append(uint16(0))                   // disk with directory
        output.append(uint16(count))
        output.append(uint16(count))
        output.append(uint32(UInt32(directory.count)))
        output.append(uint32(directoryOffset))
        output.append(uint16(0))                   // no comment
        return output
    }

    /// MS-DOS packs a timestamp into two 16-bit words, with two-second
    /// resolution and 1980 as the beginning of time.
    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(1980, parts.year ?? 1980) - 1980
        let packedDate = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        let packedTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        return (packedTime, packedDate)
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 24 & 0xFF),
        ])
    }
}

/// The checksum a ZIP entry carries, so anything else opening the archive can
/// tell that the bytes arrived intact.
enum CRC32 {
    private static let table: [UInt32] = (0...255).map { index -> UInt32 in
        (0..<8).reduce(UInt32(index)) { value, _ in
            value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
