import CryptoKit
import Foundation

/// Derives a stable identifier from content and position.
///
/// Parsing has to be a pure function: reading the same text twice must give
/// equal values, or SwiftUI loses view identity on every redraw and equality
/// stops meaning anything. A fresh `UUID()` per parse would break both.
enum StableID {
    static func make(namespace: String, index: Int, content: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace)|\(index)|\(content)".utf8))
        var bytes = [UInt8](digest.prefix(16))
        // Stamp it as a version 4 UUID so it is well-formed.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
