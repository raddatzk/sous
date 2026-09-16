import SousKit
import SwiftUI

/// A decoded picture and the proportions it has, which a crop needs and a
/// SwiftUI `Image` does not tell.
struct DecodedPicture {
    let image: Image
    let size: CGSize

    init?(data: Data) {
        #if os(macOS)
        guard let platform = NSImage(data: data) else { return nil }
        image = Image(nsImage: platform)
        #else
        guard let platform = UIImage(data: data) else { return nil }
        image = Image(uiImage: platform)
        #endif
        // Points rather than pixels on the Mac, where a JPEG's resolution
        // scales them — which is fine, since a crop only reads the ratio.
        size = platform.size
    }
}

/// A picture filling whatever frame it is given, cut around its crop.
///
/// Sizes itself to the frame rather than to the picture, so callers set the
/// shape and this only decides which part of the photo falls inside it.
struct CroppedPicture: View {
    let picture: DecodedPicture
    var crop: ImageCrop = .centered

    var body: some View {
        GeometryReader { proxy in
            let placement = crop.placement(of: picture.size, in: proxy.size)
            picture.image
                .resizable()
                .frame(width: placement.width, height: placement.height)
                .offset(x: placement.minX, y: placement.minY)
        }
        .clipped()
    }
}

/// Loads and shows one stored picture.
///
/// Lists ask for the thumbnail, detail views for the full image, so a list of
/// hundreds never pulls megabytes off disk. The thumbnail keeps the photo's
/// proportions, so the same crop cuts both the same way.
struct RecipeImageView: View {
    let imageID: UUID
    var thumbnail = false
    var crop: ImageCrop = .centered

    @Environment(RecipeLibrary.self) private var library
    @State private var picture: DecodedPicture?

    var body: some View {
        Group {
            if let picture {
                CroppedPicture(picture: picture, crop: crop)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
            }
        }
        .task(id: imageID) {
            let data = thumbnail
                ? await library.thumbnail(id: imageID)
                : await library.image(id: imageID)
            picture = data.flatMap(DecodedPicture.init(data:))
        }
    }
}
