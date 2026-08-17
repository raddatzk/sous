import SousKit
import SwiftUI

extension Image {
    /// Platform-neutral construction from image data.
    init?(data: Data) {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #endif
    }
}

/// Loads and shows one stored picture.
///
/// Lists ask for the thumbnail, detail views for the full image, so a list of
/// hundreds never pulls megabytes off disk.
struct RecipeImageView: View {
    let imageID: UUID
    var thumbnail = false
    var contentMode: ContentMode = .fill

    @Environment(RecipeLibrary.self) private var library
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = Image(data: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
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
            data = thumbnail
                ? await library.thumbnail(id: imageID)
                : await library.image(id: imageID)
        }
    }
}
