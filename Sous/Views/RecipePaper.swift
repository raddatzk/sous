import SousKit
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A recipe on paper, for the printer or as a PDF — the same page either
/// way, laid out by ``RecipeHTML`` in a web view nobody sees.
///
/// A web view rather than a text view: the page has two columns, a photo
/// and a nutrition box, and WebKit breaks pages between steps where a text
/// view could only break between lines. Paper size and margins are the
/// print dialog's, so a page set up for A4 also comes out right on Letter.
@MainActor
final class RecipePaper: NSObject, WKNavigationDelegate {
    /// Room around the page: enough for any printer's unprintable edge,
    /// little enough that a normal recipe still fits one sheet.
    private static let margins = (horizontal: 42.0, vertical: 40.0)

    /// The page being printed or saved. The print dialog and the PDF pass
    /// both outlive the call that started them, and the web view has to
    /// live until they are done.
    private static var inFlight: Set<RecipePaper> = []

    private let webView: WKWebView
    private let title: String
    private var loaded: CheckedContinuation<Void, Never>?

    private init(title: String) {
        self.title = title
        // Letter-sized to start with; the print pass lays it out again at
        // whatever paper it is given.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        super.init()
        webView.navigationDelegate = self
    }

    /// The page, laid out and ready to print.
    private static func load(_ document: RecipeDocument, picture: RecipeHTML.Picture?) async -> RecipePaper {
        // Off the main thread: shrinking the photo and encoding it takes a
        // moment, and the page should not stutter while it does.
        let html = await Task.detached { RecipeHTML.string(for: document, picture: picture) }.value
        let paper = RecipePaper(title: document.title)
        inFlight.insert(paper)
        await withCheckedContinuation { continuation in
            paper.loaded = continuation
            paper.webView.loadHTMLString(html, baseURL: nil)
        }
        return paper
    }

    private func finish() {
        Self.inFlight.remove(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume()
        loaded = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        loaded?.resume()
        loaded = nil
    }

    #if os(macOS)
    private var saved: CheckedContinuation<Bool, Never>?

    /// Opens the print panel over the key window.
    static func print(_ document: RecipeDocument, picture: RecipeHTML.Picture?) async {
        let paper = await load(document, picture: picture)
        let operation = paper.operation(info: printInfo())
        paper.run(operation)
    }

    /// The page as a PDF, on the paper the Mac is set up for.
    static func pdf(_ document: RecipeDocument, picture: RecipeHTML.Picture?) async -> Data? {
        let paper = await load(document, picture: picture)
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = paper.operation(info: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        let success = await withCheckedContinuation { continuation in
            paper.saved = continuation
            paper.run(operation)
        }
        return success ? try? Data(contentsOf: url) : nil
    }

    private static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.leftMargin = margins.horizontal
        info.rightMargin = margins.horizontal
        info.topMargin = margins.vertical
        info.bottomMargin = margins.vertical
        return info
    }

    private func operation(info: NSPrintInfo) -> NSPrintOperation {
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        return operation
    }

    /// Modal for the window, as WebKit requires: run on its own, its print
    /// operation hung and wrote a broken file hundreds of megabytes long.
    private func run(_ operation: NSPrintOperation) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            finish()
            saved?.resume(returning: false)
            saved = nil
            return
        }
        operation.runModal(
            for: window,
            delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        saved?.resume(returning: success)
        saved = nil
        finish()
    }
    #else
    /// Opens the system's print sheet.
    static func print(_ document: RecipeDocument, picture: RecipeHTML.Picture?) async {
        let paper = await load(document, picture: picture)
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = paper.title
        let formatter = paper.webView.viewPrintFormatter()
        formatter.perPageContentInsets = UIEdgeInsets(
            top: margins.vertical, left: margins.horizontal,
            bottom: margins.vertical, right: margins.horizontal
        )
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true) { _, _, _ in paper.finish() }
    }

    /// The page as a PDF — A4, or Letter where that is what the printers
    /// take.
    static func pdf(_ document: RecipeDocument, picture: RecipeHTML.Picture?) async -> Data? {
        let paper = await load(document, picture: picture)
        defer { paper.finish() }

        let sheet = CGRect(origin: .zero, size: paperSize)
        let renderer = Renderer(
            paperRect: sheet,
            printableRect: sheet.insetBy(dx: margins.horizontal, dy: margins.vertical)
        )
        renderer.addPrintFormatter(paper.webView.viewPrintFormatter(), startingAtPageAt: 0)

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, sheet, [kCGPDFContextTitle as String: paper.title])
        let pages = renderer.numberOfPages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for page in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return pages > 0 ? data as Data : nil
    }

    /// US and Canadian printers take Letter; everyone else A4.
    private static var paperSize: CGSize {
        switch Locale.current.region?.identifier {
        case "US", "CA", "MX": CGSize(width: 612, height: 792)
        default: CGSize(width: 595.2, height: 841.8)
        }
    }

    /// A page renderer told its paper up front — the stock one only learns
    /// it from a print job.
    private final class Renderer: UIPrintPageRenderer {
        private let paper: CGRect
        private let printable: CGRect

        init(paperRect: CGRect, printableRect: CGRect) {
            paper = paperRect
            printable = printableRect
            super.init()
        }

        override var paperRect: CGRect { paper }
        override var printableRect: CGRect { printable }
    }
    #endif
}
