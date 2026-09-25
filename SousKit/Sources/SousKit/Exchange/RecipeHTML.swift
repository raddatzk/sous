import CoreGraphics
import Foundation
import ImageIO

/// A recipe as a printed page — what ⌘P prints and what the PDF export
/// saves, laid out once in HTML so the two cannot drift apart and the page
/// breaks are the web engine's, not hand-computed.
///
/// The page is meant for the kitchen: the ingredients in a narrow column
/// beside the steps, so both are in view without turning the sheet; a box
/// to tick per ingredient; room to write under the notes; the source as a
/// QR code, since nobody types a URL off paper. One accent colour, used
/// sparingly enough that a black-and-white printer loses nothing.
///
/// Black on white whatever the app's appearance — paper has no dark mode.
/// Margins and paper size are the print dialog's; the page only lays out
/// what it is given.
public enum RecipeHTML {
    /// The recipe's first photo and where it was cropped.
    public struct Picture: Sendable {
        public var data: Data
        public var crop: ImageCrop

        public init(data: Data, crop: ImageCrop = .centered) {
            self.data = data
            self.crop = crop
        }
    }

    public static func string(for document: RecipeDocument, picture: Picture? = nil) -> String {
        var html = """
        <!doctype html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <title>\(escape(document.title))</title>
        <style>\(css)</style>
        </head>
        <body>

        """
        html += header(document, picture: picture)
        html += facts(document)

        let hasIngredients = !document.ingredientGroups.isEmpty
        let hasSteps = !document.stepGroups.isEmpty
        let layout = hasIngredients && hasSteps ? "columns" : "single"
        html += "<div class=\"body \(layout)\">\n"
        if hasIngredients {
            html += "<section class=\"ingredients\">\n<h2>Zutaten</h2>\n"
            html += document.ingredientGroups.map(ingredientGroup).joined()
            html += nutrition(document.nutrition)
            html += "</section>\n"
        }
        html += "<section class=\"steps\">\n"
        if hasSteps {
            html += "<h2>Zubereitung</h2>\n"
            html += document.stepGroups.map(stepGroup).joined()
        }
        html += notes(document.notes)
        if !hasIngredients {
            html += nutrition(document.nutrition)
        }
        html += "</section>\n</div>\n"
        html += footer(document.source, appLink: document.appLink)
        html += "</body>\n</html>\n"
        return html
    }

    // MARK: - Parts

    private static func header(_ document: RecipeDocument, picture: Picture?) -> String {
        var html = "<header class=\"head\">\n<div class=\"head-text\">\n"
        if !document.categories.isEmpty {
            html += "<p class=\"kicker\">\(document.categories.map(escape).joined(separator: " · "))</p>\n"
        }
        html += "<h1>\(escape(document.title))</h1>\n"
        if let summary = document.summary {
            html += "<p class=\"summary\">\(paragraphs(summary))</p>\n"
        }
        html += "</div>\n"
        if let picture, let figure = figure(picture) {
            html += figure
        }
        html += "</header>\n"
        return html
    }

    private static func facts(_ document: RecipeDocument) -> String {
        let items = [("Portionen", "\(document.servings)")] + document.times.map { ($0.label, $0.value) }
        let cells = items.map { label, value in
            "<div><dt>\(escape(label))</dt><dd>\(escape(value))</dd></div>"
        }
        return "<dl class=\"facts\">\(cells.joined())</dl>\n"
    }

    private static func ingredientGroup(_ group: RecipeDocument.IngredientGroup) -> String {
        var html = "<div class=\"group\">\n"
        if let name = group.name { html += "<h3>\(escape(name))</h3>\n" }
        html += "<ul>\n"
        for line in group.lines {
            html += "<li><span class=\"box\"></span><span class=\"amount\">\(escape(line.amount))</span>"
            html += "<span class=\"text\">\(escape(line.text))</span></li>\n"
        }
        html += "</ul>\n</div>\n"
        return html
    }

    private static func stepGroup(_ group: RecipeDocument.StepGroup) -> String {
        var html = "<div class=\"group\">\n"
        if let name = group.name { html += "<h3>\(escape(name))</h3>\n" }
        html += "<ol>\n"
        for step in group.steps {
            let text = step.segments.map { segment in
                switch segment {
                case .text(let string): paragraphs(string)
                case .amount(let string): "<b>\(escape(string))</b>"
                }
            }.joined()
            html += "<li><span class=\"number\">\(step.number)</span><p>\(text)</p></li>\n"
        }
        html += "</ol>\n</div>\n"
        return html
    }

    /// Always there, written on or not: notes are what a printed recipe
    /// collects in pencil.
    private static func notes(_ notes: String?) -> String {
        var html = "<div class=\"notes\">\n<h2>Notizen</h2>\n"
        if let notes { html += "<p>\(paragraphs(notes))</p>\n" }
        html += "<div class=\"rule\"></div><div class=\"rule\"></div><div class=\"rule\"></div>\n</div>\n"
        return html
    }

    private static func nutrition(_ nutrition: RecipeDocument.Nutrition?) -> String {
        guard let nutrition else { return "" }
        var html = "<div class=\"nutrition\">\n<p class=\"label\">Nährwerte"
        if nutrition.isProvisional { html += " <span class=\"provisional\">vorläufig</span>" }
        html += "</p>\n"
        for row in nutrition.rows {
            html += "<div class=\"row\(row.isIndented ? " indented" : "")\">"
            html += "<span>\(escape(row.label))</span><span>\(escape(row.value))</span></div>\n"
        }
        html += "<p class=\"caption\">\(escape(nutrition.caption)).</p>\n</div>\n"
        return html
    }

    /// Two ways back from paper, one in each corner: where the recipe came
    /// from on the left, the recipe in Sous on the right.
    private static func footer(_ source: RecipeDocument.Source?, appLink: URL?) -> String {
        var html = "<footer>\n<div class=\"source\">"
        if let source {
            if let url = source.url, let code = QRCode.svg(for: url.absoluteString) {
                html += "<div class=\"qr\">\(code)</div>"
            }
            html += "<div>"
            if let url = source.url {
                html += "<span class=\"name\">\(escape(source.name))</span><br>"
                html += "<span class=\"url\">\(escape(url.absoluteString))</span>"
            } else {
                html += "<span class=\"name\">\(escape(source.name))</span>"
            }
            html += "</div>"
        }
        html += "</div>\n<div class=\"app\">"
        html += "<div><span class=\"mark\">Sous</span>"
        if let appLink, let code = QRCode.svg(for: appLink.absoluteString) {
            html += "<br><span class=\"hint\">In der App öffnen</span></div><div class=\"qr\">\(code)</div>"
        } else {
            html += "</div>"
        }
        html += "</div>\n</footer>\n"
        return html
    }

    /// The photo in a fixed frame, cut around its focus the way the app
    /// cuts it — by placing the whole picture, not by clipping a copy.
    private static func figure(_ picture: Picture) -> String? {
        // Enough for 300 dpi across the frame, and no more: the full photo
        // would make every PDF several megabytes.
        guard let data = RecipeImageProcessing.resized(picture.data, maxPixel: 900),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }

        let frame = CGSize(width: 4, height: 3)
        let placed = picture.crop.placement(of: CGSize(width: width, height: height), in: frame)
        func percent(_ value: CGFloat, of whole: CGFloat) -> String {
            String(format: "%.3f%%", locale: Locale(identifier: "en_US_POSIX"), value / whole * 100)
        }
        let style = "left:\(percent(placed.minX, of: frame.width));top:\(percent(placed.minY, of: frame.height));"
            + "width:\(percent(placed.width, of: frame.width));height:\(percent(placed.height, of: frame.height))"
        return """
        <figure class="photo"><img src="data:image/jpeg;base64,\(data.base64EncodedString())" style="\(style)" alt=""></figure>

        """
    }

    // MARK: - Text

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Line breaks kept as they were typed.
    private static func paragraphs(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: - Style

    private static let css = """
    :root {
      --ink: #1d1b19;
      --muted: #6b6660;
      --rule: #d8d2ca;
      --accent: #b4451e;
      --serif: ui-serif, "New York", Georgia, serif;
    }
    * { box-sizing: border-box; }
    html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    body {
      margin: 0;
      color: var(--ink);
      background: #fff;
      font: 10pt/1.45 -apple-system, "Helvetica Neue", Helvetica, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    h1, h2, h3, p, ul, ol, dl, dd, figure { margin: 0; padding: 0; }
    ul, ol { list-style: none; }

    .head { display: flex; gap: 6mm; align-items: flex-start; break-inside: avoid; }
    .head-text { flex: 1; min-width: 0; }
    .kicker {
      color: var(--accent);
      font-size: 7.5pt;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      margin-bottom: 1.5mm;
    }
    h1 { font: 600 24pt/1.12 var(--serif); margin-bottom: 2mm; }
    .summary { font: italic 11pt/1.45 var(--serif); color: var(--muted); }
    .photo {
      flex: none;
      position: relative;
      width: 52mm;
      height: 39mm;
      overflow: hidden;
      background: #ece7e1;
    }
    .photo img { position: absolute; display: block; }

    .facts {
      display: flex;
      margin: 5mm 0 6mm;
      padding: 1.8mm 0;
      border-top: 0.75pt solid var(--ink);
      border-bottom: 0.5pt solid var(--rule);
      break-inside: avoid;
    }
    .facts > div { flex: 1; padding: 0 3mm; border-left: 0.5pt solid var(--rule); }
    .facts > div:first-child { padding-left: 0; border-left: none; }
    .facts dt { font-size: 6.5pt; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
    .facts dd { font-weight: 600; font-size: 10.5pt; }

    h2 {
      font: 600 13pt/1.2 var(--serif);
      padding-bottom: 1mm;
      margin-bottom: 1.5mm;
      border-bottom: 0.75pt solid var(--accent);
      break-after: avoid;
    }
    h3 { font: italic 10.5pt/1.3 var(--serif); margin: 3mm 0 1mm; break-after: avoid; }
    .group:first-of-type h3 { margin-top: 1.5mm; }

    .body.columns::after { content: ""; display: block; clear: both; }
    .body.columns .ingredients { float: left; width: 36%; padding-right: 6mm; }
    .body.columns .steps { margin-left: 36%; }

    .ingredients li { display: flex; align-items: baseline; gap: 1.8mm; margin: 0.6mm 0; break-inside: avoid; }
    .box {
      flex: none;
      width: 2.4mm;
      height: 2.4mm;
      border: 0.6pt solid #8a847c;
      border-radius: 0.4mm;
      transform: translateY(0.2mm);
    }
    .amount {
      flex: none;
      min-width: 13mm;
      text-align: right;
      font-weight: 600;
      font-variant-numeric: tabular-nums;
    }
    .amount:empty { min-width: 13mm; }
    .text { flex: 1; min-width: 0; }

    .steps li { display: flex; gap: 2.5mm; margin-bottom: 2.4mm; break-inside: avoid; }
    .number {
      flex: none;
      width: 6mm;
      text-align: right;
      font: 600 16pt/1 var(--serif);
      color: var(--accent);
      padding-top: 0.4mm;
    }
    .steps li p { flex: 1; min-width: 0; }
    .steps b { font-weight: 600; }

    .notes { margin-top: 5mm; break-inside: avoid; }
    .notes p { color: var(--muted); margin-bottom: 1mm; }
    .rule { height: 6.5mm; border-bottom: 0.5pt solid var(--rule); }

    .nutrition {
      margin-top: 5mm;
      padding: 1.8mm 2.2mm;
      border: 0.75pt solid var(--ink);
      font-size: 8pt;
      line-height: 1.5;
      break-inside: avoid;
    }
    .nutrition .label {
      font-weight: 600;
      font-size: 9pt;
      padding-bottom: 0.8mm;
      margin-bottom: 0.8mm;
      border-bottom: 1.5pt solid var(--ink);
    }
    .nutrition .row { display: flex; justify-content: space-between; gap: 2mm; }
    .nutrition .row.indented { padding-left: 3mm; color: var(--muted); }
    .nutrition .row span:last-child { font-variant-numeric: tabular-nums; white-space: nowrap; }
    .nutrition .caption { margin-top: 1mm; font-size: 7pt; color: var(--muted); }
    .provisional { font-weight: 400; color: var(--accent); }

    footer {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 6mm;
      margin-top: 7mm;
      padding-top: 2.5mm;
      border-top: 0.5pt solid var(--rule);
      font-size: 7.5pt;
      color: var(--muted);
      break-inside: avoid;
    }
    .source { display: flex; align-items: center; gap: 2.5mm; min-width: 0; }
    .qr { flex: none; width: 15mm; height: 15mm; }
    .qr svg { display: block; width: 100%; height: 100%; fill: var(--ink); }
    .source .name { color: var(--ink); }
    .source .url { word-break: break-all; }
    .app { flex: none; display: flex; align-items: center; gap: 2.5mm; text-align: right; }
    .mark { font: 600 11pt var(--serif); color: var(--accent); }
    """
}
