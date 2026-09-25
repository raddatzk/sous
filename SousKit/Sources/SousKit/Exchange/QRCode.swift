import CoreImage
import Foundation

/// A QR code as its grid of modules, so the page can draw it as vectors:
/// sharp at any printer resolution, where a bitmap would be scaled and
/// blurred on the way to paper.
enum QRCode {
    /// Rows of modules, `true` for dark, including the quiet zone the
    /// generator leaves around the code. `nil` where the text does not fit.
    static func modules(for text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // M: a smudge or a fold in a kitchen printout still scans.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }

        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // One byte per module: the generator's output is one pixel per module.
        var pixels = [UInt8](repeating: 255, count: width * height)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            image,
            toBitmap: &pixels,
            rowBytes: width,
            bounds: extent,
            format: .L8,
            colorSpace: nil
        )
        return (0..<height).map { row in
            (0..<width).map { column in pixels[row * width + column] < 128 }
        }
    }

    /// The code as an inline SVG, one path of unit squares.
    static func svg(for text: String) -> String? {
        guard let modules = modules(for: text), let size = modules.first?.count else { return nil }
        var path = ""
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                path += "M\(x) \(y)h1v1h-1z"
            }
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(size) \(modules.count)" \
        shape-rendering="crispEdges" aria-hidden="true"><path d="\(path)"/></svg>
        """
    }
}
