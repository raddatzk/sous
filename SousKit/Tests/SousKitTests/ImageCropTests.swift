import CoreGraphics
import Foundation
import Testing
@testable import SousKit

@Suite("Image crops")
struct ImageCropTests {
    /// A landscape photo, the usual shape of a plate.
    private let photo = CGSize(width: 400, height: 300)

    @Test("Uncropped, a picture fills the frame from its middle")
    func centeredIsAPlainFill() {
        let placement = ImageCrop.centered.placement(of: photo, in: CGSize(width: 100, height: 100))
        #expect(abs(placement.width - 400.0 / 3) < 0.001)
        #expect(placement.height == 100)
        #expect(abs(placement.midX - 50) < 0.001)
        #expect(placement.minY == 0)
    }

    @Test("A focus to one side moves the cut, but never past the picture's edge")
    func focusStopsAtTheEdge() {
        let square = CGSize(width: 100, height: 100)
        let left = ImageCrop(focusX: 0.1, focusY: 0.5).placement(of: photo, in: square)
        #expect(left.minX == 0)

        let right = ImageCrop(focusX: 0.9, focusY: 0.5).placement(of: photo, in: square)
        #expect(abs(right.maxX - 100) < 0.001)

        // A frame the picture already fills in that direction has nothing to
        // cut, so the focus cannot shift it; the other direction still moves.
        let wide = ImageCrop(focusX: 0.1, focusY: 0.9).placement(of: photo, in: CGSize(width: 400, height: 100))
        #expect(wide.minX == 0)
        #expect(wide.maxY == 100)
    }

    @Test("Zooming in keeps the focus in the middle of the frame")
    func zoomCentersTheFocus() {
        let crop = ImageCrop(focusX: 0.5, focusY: 0.4, zoom: 2)
        let frame = CGSize(width: 200, height: 150)
        let placement = crop.placement(of: photo, in: frame)
        #expect(placement.size == CGSize(width: 400, height: 300))
        let focus = CGPoint(
            x: placement.minX + crop.focusX * placement.width,
            y: placement.minY + crop.focusY * placement.height
        )
        #expect(abs(focus.x - 100) < 0.001)
        #expect(abs(focus.y - 75) < 0.001)
    }

    @Test("Values from outside the range are clamped rather than trusted")
    func clamping() throws {
        let crop = ImageCrop(focusX: -2, focusY: .nan, zoom: 10)
        #expect(crop == ImageCrop(focusX: 0, focusY: 0.5, zoom: 3))

        let json = #"{"focusX": 1.5, "focusY": 0.2, "zoom": 0.1}"#
        let decoded = try JSONDecoder().decode(ImageCrop.self, from: Data(json.utf8))
        #expect(decoded == ImageCrop(focusX: 1, focusY: 0.2, zoom: 1))
    }

    @Test("The stored form keeps chosen crops and drops centered ones")
    func storedForm() {
        let chosen = UUID()
        let crops = [chosen: ImageCrop(focusX: 0.3, focusY: 0.6, zoom: 1.2), UUID(): .centered]

        let json = ImageCrop.encode(crops)
        #expect(ImageCrop.decode(json) == [chosen: crops[chosen]!])
        #expect(ImageCrop.encode([UUID(): .centered]) == nil)
        #expect(ImageCrop.decode(nil).isEmpty)
        #expect(ImageCrop.decode("not json").isEmpty)
    }
}
