import SousKit
import SwiftUI

/// Where a picture should be cut: the point that matters and how close to go.
///
/// The whole photo on top, with the chosen point marked on it, and below it
/// the picture in every shape the app shows it in. The shapes are the reason
/// this is a point and not a rectangle — see ``ImageCrop`` — so they are
/// shown side by side rather than one at a time: whether the square in the
/// list still has the plate in it is the question being answered.
struct ImageCropEditor: View {
    let imageID: UUID
    let onDone: (ImageCrop) -> Void

    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var crop: ImageCrop
    @State private var picture: DecodedPicture?
    /// The zoom a pinch started from, so the gesture scales it rather than
    /// replacing it.
    @State private var pinchBase: Double?
    private let initialCrop: ImageCrop

    init(imageID: UUID, crop: ImageCrop, onDone: @escaping (ImageCrop) -> Void) {
        self.imageID = imageID
        self.onDone = onDone
        _crop = State(initialValue: crop)
        initialCrop = crop
    }

    /// The shapes a recipe's picture takes, with the proportions each has.
    ///
    /// The header's are typical widths over its fixed 320 points: a phone
    /// held upright, and an iPad or Mac window, which is where the strip
    /// gets so wide that a tall dish loses its top and bottom.
    private static let shapes: [(name: String, ratio: CGFloat)] = [
        ("Rezept auf iPad und Mac", 900 / 320),
        ("Rezept auf dem iPhone", 393 / 320),
        ("Karte", 4 / 3),
        ("Liste", 1),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let picture {
                        canvas(picture)
                        zoomControl
                        previews(picture)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding()
            }
            .background(Color.sousBackground)
            .navigationTitle("Ausschnitt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        onDone(crop)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") {
                        withAnimation { crop = .centered }
                    }
                    .disabled(crop.isCentered)
                }
            }
            .task(id: imageID) {
                picture = await library.image(id: imageID).flatMap(DecodedPicture.init(data:))
            }
        }
        // Swiping away would drop the draft without a word; once there is
        // something to lose, only the two buttons close it.
        .interactiveDismissDisabled(crop != initialCrop)
        .sousSheetSizing(.page)
    }

    /// The whole photo. Touching it moves the point to keep in view; pinching
    /// goes closer or further out.
    private func canvas(_ picture: DecodedPicture) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            picture.image
                .resizable()
                .aspectRatio(picture.size, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 360)
                .overlay {
                    GeometryReader { proxy in
                        focusMark
                            .position(
                                x: crop.focusX * proxy.size.width,
                                y: crop.focusY * proxy.size.height
                            )
                            .allowsHitTesting(false)
                        Color.clear
                            .contentShape(.rect)
                            .gesture(focusDrag(in: proxy.size))
                            .simultaneousGesture(pinch)
                    }
                }
                .clipShape(.rect(cornerRadius: SousStyle.fieldRadius))
                .accessibilityElement()
                .accessibilityLabel("Foto")
                .accessibilityValue(focusDescription)
                .accessibilityAdjustableAction { direction in
                    // VoiceOver has no point to drag; up and down walk the
                    // point through the picture's height, which is the
                    // direction a landscape photo loses most in a square.
                    let step = direction == .increment ? -0.1 : 0.1
                    crop = ImageCrop(focusX: crop.focusX, focusY: crop.focusY + step, zoom: crop.zoom)
                }

            Text("Tippe auf das, was sichtbar bleiben soll. Jede Ansicht schneidet ihre Form um diesen Punkt zu.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var focusMark: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 2.5)
            .background(Circle().fill(.black.opacity(0.2)))
            .frame(width: 34, height: 34)
            .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private var focusDescription: String {
        let horizontal = crop.focusX < 0.4 ? "links" : crop.focusX > 0.6 ? "rechts" : "Mitte"
        let vertical = crop.focusY < 0.4 ? "oben" : crop.focusY > 0.6 ? "unten" : "Mitte"
        return "Punkt \(vertical), \(horizontal)"
    }

    private func focusDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                crop = ImageCrop(
                    focusX: value.location.x / size.width,
                    focusY: value.location.y / size.height,
                    zoom: crop.zoom
                )
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? crop.zoom
                pinchBase = base
                crop = ImageCrop(focusX: crop.focusX, focusY: crop.focusY, zoom: base * value.magnification)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var zoomControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { crop.zoom },
                    set: { crop = ImageCrop(focusX: crop.focusX, focusY: crop.focusY, zoom: $0) }
                ),
                in: ImageCrop.zoomRange
            )
            .accessibilityLabel("Zoom")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    /// The widest shape across the whole sheet, the rest in a row under it at
    /// one height, so they compare as shapes rather than as sizes.
    private func previews(_ picture: DecodedPicture) -> some View {
        let wide = Self.shapes[0]
        let rest = Self.shapes.dropFirst()
        return VStack(alignment: .leading, spacing: 14) {
            preview(picture, name: wide.name) {
                $0.aspectRatio(wide.ratio, contentMode: .fit)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(rest, id: \.name) { shape in
                    preview(picture, name: shape.name) {
                        $0.frame(width: 90 * shape.ratio, height: 90)
                    }
                    .frame(width: 90 * shape.ratio)
                }
            }
        }
    }

    private func preview(
        _ picture: DecodedPicture,
        name: String,
        shape: (CroppedPicture) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            shape(CroppedPicture(picture: picture, crop: crop))
                .clipShape(.rect(cornerRadius: SousStyle.thumbnailRadius))
                .accessibilityHidden(true)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
