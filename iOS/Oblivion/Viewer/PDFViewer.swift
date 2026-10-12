//
//  PDFViewer.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import PDFKit

final class PDFViewer: NSObject, Viewable {
    let pdfView = PDFView()
    var onPageChange: ((Int) -> Void)?
    var contentView: UIView { pdfView }
    var pageCount: Int { pdfView.document?.pageCount ?? 0 }
    var currentPage: Int { pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0 }
    var isZoomed: Bool { pdfView.scaleFactor > pdfView.scaleFactorForSizeToFit + 0.001 }

    private init(document: PDFDocument) {
        super.init()
        pdfView.backgroundColor = .black
        pdfView.pageShadowsEnabled = false
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true)
        pdfView.document = document
        pdfView.autoScales = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView
        )
    }

    static func open(_ url: URL) async -> Result<any Viewable, ViewerError> {
        let document = await loadDocument(at: url)
        guard !Task.isCancelled else { return .failure(.rendering(.Cancelled)) }
        guard let document else { return .failure(.cannotOpen(url)) }
        return .success(PDFViewer(document: document))
    }

    @concurrent private static func loadDocument(at url: URL) async -> sending PDFDocument? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        return document
    }

    func fitToView() {
        pdfView.layoutIfNeeded()
        let fit = pdfView.scaleFactorForSizeToFit
        pdfView.minScaleFactor = fit
        pdfView.maxScaleFactor = fit * 4
        pdfView.scaleFactor = fit
    }

    func toggleZoom(at point: CGPoint) {
        pdfView.scaleFactor = isZoomed ? pdfView.scaleFactorForSizeToFit : pdfView.scaleFactorForSizeToFit * 2
    }

    @objc private func pageChanged(_ notification: Notification) {
        onPageChange?(currentPage)
    }
}
