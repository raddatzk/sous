import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares picked photos for storage.
///
/// A photo out of the library is several megabytes, and every byte of it would
/// be encrypted and synced again on any change. Recipes need a picture of a
/// dish, not a printable original, so images are downsized on the way in.
public enum RecipeImageProcessing {
    /// Long edge of a stored image.
    public static let maxPixelSize: CGFloat = 2048
    /// Long edge of the version shown in lists.
    public static let thumbnailPixelSize: CGFloat = 400

    public struct Prepared: Sendable {
        public let data: Data
        public let thumbnail: Data
    }

    public static func prepare(_ data: Data) -> Prepared? {
        guard let full = resized(data, maxPixel: maxPixelSize),
              let thumbnail = resized(data, maxPixel: thumbnailPixelSize)
        else { return nil }
        return Prepared(data: full, thumbnail: thumbnail)
    }

    /// Downsizes so the long edge is at most `maxPixel`, re-encoded as JPEG.
    ///
    /// Uses ImageIO's thumbnail path, which decodes at the target size rather
    /// than decoding the full image first — a 48-megapixel photo never has to
    /// exist in memory at full size.
    public static func resized(_ data: Data, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
