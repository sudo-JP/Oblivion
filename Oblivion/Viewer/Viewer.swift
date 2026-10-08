//
//  Viewer.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import UIKit

enum ViewerError: LocalizedError {
    case unsupportedExtension(String)
    case cannotOpen(URL)
    case noPages
    case rendering(RetrieveViewableError)

    var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(fileExtension):
            return fileExtension.isEmpty
                ? "This file has no supported extension."
                : "Files with the .\(fileExtension) extension are not supported."
        case let .cannotOpen(url):
            return "Could not open \(url.lastPathComponent)."
        case .noPages:
            return "This document has no readable pages."
        case let .rendering(error):
            switch error {
            case .IndexOutOfRange:
                return "The requested document page is unavailable."
            case .InvalidSize:
                return "The requested preview size is invalid."
            case .InvalidPageBounds:
                return "This document page has invalid dimensions."
            }
        }
    }
}

class Viewer: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    struct Document {
        let url: URL
        let content: any Viewable
    }

    private static let renderersByExtension: [String: (URL) -> (any Viewable)?] = [
        "pdf": { PDFViewer(url: $0) },
        "jpg": { ImageViewer(url: $0) },
        "jpeg": { ImageViewer(url: $0) },
        "png": { ImageViewer(url: $0) },
        "heic": { ImageViewer(url: $0) },
        "heif": { ImageViewer(url: $0) },
        "gif": { ImageViewer(url: $0) },
        "bmp": { ImageViewer(url: $0) },
        "tif": { ImageViewer(url: $0) },
        "tiff": { ImageViewer(url: $0) },
        "webp": { ImageViewer(url: $0) }
    ]

    var document: Document?
    private var currentPage = 0
    private var lastPageSize = CGSize.zero

    @IBOutlet weak var pageCollectionView: UICollectionView!
    
    @IBOutlet weak var topBarView: UIView!
    @IBOutlet weak var bottomBarView: UIView!
    
    @IBOutlet weak var fileNameLabel: UILabel!
    
    @IBOutlet weak var pageCountLabel: UILabel!
    
    @IBAction func showDocumentActions(_ sender: Any) {
    }

    static func loadDocument(at url: URL) -> Result<Document, ViewerError> {
        guard url.isFileURL else { return .failure(.cannotOpen(url)) }
        let fileExtension = url.pathExtension.lowercased()
        guard let renderer = renderersByExtension[fileExtension] else {
            return .failure(.unsupportedExtension(fileExtension))
        }
        guard let content = renderer(url) else { return .failure(.cannotOpen(url)) }
        guard content.pageCount > 0 else { return .failure(.noPages) }
        return .success(Document(url: url, content: content))
    }

    static func thumbnail(for url: URL, size: CGSize) -> Result<UIImage, ViewerError> {
        loadDocument(at: url).flatMap { document in
            document.content.image(forPage: 0, size: size).mapError { .rendering($0) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let document else {
            preconditionFailure("ShowViewer must supply a document before loading Viewer.")
        }
        fileNameLabel.text = document.url.lastPathComponent
        pageCountLabel.text = "1 / \(document.content.pageCount)"
        pageCollectionView.contentInsetAdjustmentBehavior = .never
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = pageCollectionView.bounds.size
        guard size.width > 0, size.height > 0, size != lastPageSize else { return }
        lastPageSize = size
        pageCollectionView.collectionViewLayout.invalidateLayout()
        pageCollectionView.reloadData()
        pageCollectionView.layoutIfNeeded()
        pageCollectionView.setContentOffset(
            CGPoint(x: CGFloat(currentPage) * size.width, y: 0),
            animated: false
        )
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let document else {
            preconditionFailure("Viewer requires a document.")
        }
        return document.content.pageCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let document else {
            preconditionFailure("Viewer requires a document.")
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PageCell", for: indexPath)
        guard let imageView = cell.contentView.viewWithTag(301) as? UIImageView else {
            preconditionFailure("PageCell must contain an image view with tag 301.")
        }
        imageView.image = nil
        let size = CGSize(
            width: collectionView.bounds.width - 24,
            height: collectionView.bounds.height - 24
        )
        switch document.content.image(forPage: indexPath.item, size: size) {
        case let .success(image):
            imageView.image = image
        case let .failure(error):
            let message = ViewerError.rendering(error).localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.displayError(message: message)
            }
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentPage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateCurrentPage()
        }
    }

    private func updateCurrentPage() {
        guard let document else {
            preconditionFailure("Viewer requires a document.")
        }
        let width = pageCollectionView.bounds.width
        guard width > 0 else { return }
        let page = Int((pageCollectionView.contentOffset.x / width).rounded())
        currentPage = min(max(page, 0), document.content.pageCount - 1)
        pageCountLabel.text = "\(currentPage + 1) / \(document.content.pageCount)"
    }

    private func displayError(message: String) {
        print(message)
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Viewer Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
