import CoreGraphics
import Foundation

/// Which part of a picture stays in view when a frame cuts it.
///
/// One choice per picture rather than one rectangle per place it is shown.
/// The same dish is a square in a list row, four to three on a card and a
/// wide strip over the recipe, and the strip is wider on an iPad than on a
/// phone — a rectangle drawn for one of them is wrong for every other, and a
/// rectangle per shape would ask the cook to crop the same photo four times
/// and again for every layout added later. What they actually know is what
/// the photo is *of*: the point that matters, and how close to go. Every
/// frame then cuts its own shape around that.
///
/// The original is never touched, so a choice can always be taken back.
public struct ImageCrop: Codable, Hashable, Sendable {
    /// The point to keep in view, as a fraction of the picture's width from
    /// the left edge.
    public var focusX: Double
    /// The same, as a fraction of its height from the top edge.
    public var focusY: Double
    /// How much closer than the smallest fill: 1 shows as much of the
    /// picture as the frame allows.
    public var zoom: Double

    public static let zoomRange: ClosedRange<Double> = 1...3

    /// What a picture nobody has cropped shows: its middle, as far out as
    /// the frame goes — the same as a plain fill.
    public static let centered = ImageCrop(focusX: 0.5, focusY: 0.5, zoom: 1)

    public init(focusX: Double, focusY: Double, zoom: Double = 1) {
        // Clamped on the way in, so a value synced from a sloppier writer
        // cannot push the picture out of its own frame.
        self.focusX = Self.unit(focusX)
        self.focusY = Self.unit(focusY)
        self.zoom = zoom.isFinite
            ? min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            : 1
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            focusX: try container.decode(Double.self, forKey: .focusX),
            focusY: try container.decode(Double.self, forKey: .focusY),
            zoom: try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        )
    }

    public var isCentered: Bool { self == .centered }

    /// Where a picture of `imageSize` goes, in the coordinates of a frame of
    /// `frameSize`, so that it fills the frame with the focus as near the
    /// middle as the picture's edges allow.
    ///
    /// Near rather than at: a focus close to an edge would otherwise pull
    /// the picture off that edge and show the frame's background beside it.
    /// The frame is always filled; the focus only decides which way the
    /// spare picture is cut.
    public func placement(of imageSize: CGSize, in frameSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: frameSize)
        }
        let scale = max(frameSize.width / imageSize.width, frameSize.height / imageSize.height) * zoom
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let x = frameSize.width / 2 - focusX * size.width
        let y = frameSize.height / 2 - focusY * size.height
        return CGRect(
            x: min(max(x, frameSize.width - size.width), 0),
            y: min(max(y, frameSize.height - size.height), 0),
            width: size.width,
            height: size.height
        )
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

extension ImageCrop {
    /// The crops of a recipe's pictures as one JSON object keyed by image id —
    /// the form both stores keep them in. `nil` where there are none, so a
    /// recipe nobody cropped writes nothing.
    static func encode(_ crops: [UUID: ImageCrop]) -> String? {
        let chosen = crops.filter { !$0.value.isCentered }
        guard !chosen.isEmpty else { return nil }
        let keyed = Dictionary(uniqueKeysWithValues: chosen.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(keyed) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads what ``encode(_:)`` wrote. Anything unreadable reads as
    /// uncropped rather than as an error: the worst a lost crop does is show
    /// the middle of the picture.
    static func decode(_ json: String?) -> [UUID: ImageCrop] {
        guard let data = json?.data(using: .utf8),
              let keyed = try? JSONDecoder().decode([String: ImageCrop].self, from: data)
        else { return [:] }
        var crops: [UUID: ImageCrop] = [:]
        for (key, crop) in keyed {
            if let id = UUID(uuidString: key) { crops[id] = crop }
        }
        return crops
    }
}
