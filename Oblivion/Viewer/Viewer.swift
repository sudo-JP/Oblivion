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
    private var controlsVisible = true
    private var autoHideTimer: Timer?
    private var previousIdleTimerSetting: Bool?

    @IBOutlet weak var pageCollectionView: UICollectionView!
    
    @IBOutlet weak var topBarView: UIView!
    
    @IBOutlet weak var fileNameLabel: UILabel!
    
    @IBAction func showDocumentActions(_ sender: Any) {
        restartAutoHideTimer()
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

    static func supportsFile(at url: URL) -> Bool {
        url.isFileURL && renderersByExtension[url.pathExtension.lowercased()] != nil
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
        pageCollectionView.contentInsetAdjustmentBehavior = .never

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        pageCollectionView.addGestureRecognizer(singleTap)
        pageCollectionView.addGestureRecognizer(doubleTap)

        NotificationCenter.default.addObserver(
            self, selector: #selector(readerWillResignActive(_:)),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(readerDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceOverStatusChanged(_:)),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if previousIdleTimerSetting == nil {
            previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
        setControlsVisible(true, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        autoHideTimer?.invalidate()
        if let previousIdleTimerSetting {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            self.previousIdleTimerSetting = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = pageCollectionView.bounds.size
        guard size.width > 0, size.height > 0, size != lastPageSize else { return }
        lastPageSize = size
        pageCollectionView.isScrollEnabled = true
        pageCollectionView.collectionViewLayout.invalidateLayout()
        pageCollectionView.reloadData()
        pageCollectionView.layoutIfNeeded()
        pageCollectionView.setContentOffset(
            CGPoint(x: CGFloat(currentPage) * size.width, y: 0),
            animated: false
        )
        restartAutoHideTimer()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let document else {
            preconditionFailure("Viewer requires a document.")
        }
        return document.content.pageCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PageCell", for: indexPath)
        guard let imageView = cell.contentView.viewWithTag(301) as? UIImageView,
              let scrollView = cell.contentView.viewWithTag(302) as? UIScrollView else {
            preconditionFailure("PageCell requires an image (301) inside a zoom scroll view (302).")
        }
        scrollView.delegate = nil
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.contentOffset = .zero
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.delegate = self
        imageView.image = nil
        let size = CGSize(
            width: collectionView.bounds.width - 24,
            height: collectionView.bounds.height - 24
        )
        renderPage(indexPath.item, in: imageView, size: size)
        return cell
    }

    private func renderPage(_ index: Int, in imageView: UIImageView, size: CGSize) {
        guard let document else {
            preconditionFailure("Viewer requires a document.")
        }
        switch document.content.image(forPage: index, size: size) {
        case let .success(image):
            imageView.image = image
        case let .failure(error):
            let message = ViewerError.rendering(error).localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.displayError(message: message)
            }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === pageCollectionView {
            updateCurrentPage()
        }
        restartAutoHideTimer()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        autoHideTimer?.invalidate()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isDragging || scrollView.isDecelerating {
            autoHideTimer?.invalidate()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            if scrollView === pageCollectionView {
                updateCurrentPage()
            }
            restartAutoHideTimer()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        guard scrollView.tag == 302 else { return nil }
        guard let imageView = scrollView.viewWithTag(301) as? UIImageView else {
            preconditionFailure("The zoom scroll view requires an image with tag 301.")
        }
        return imageView
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        autoHideTimer?.invalidate()
        pageCollectionView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        let center = scrollView.convert(
            CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: pageCollectionView
        )
        if let indexPath = pageCollectionView.indexPathForItem(at: center) {
            pageCollectionView.setContentOffset(
                CGPoint(x: CGFloat(indexPath.item) * pageCollectionView.bounds.width, y: 0),
                animated: false
            )
            updateCurrentPage()
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView.tag == 302 else { return }
        autoHideTimer?.invalidate()
        updatePaging(for: scrollView)
    }

    private func updatePaging(for scrollView: UIScrollView) {
        let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.001
        scrollView.panGestureRecognizer.isEnabled = isZoomed
        pageCollectionView.isScrollEnabled = !isZoomed
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView.tag == 302 else { return }
        updatePaging(for: scrollView)
        let center = scrollView.convert(
            CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: pageCollectionView
        )
        guard let indexPath = pageCollectionView.indexPathForItem(at: center),
              let imageView = view as? UIImageView,
              let image = imageView.image else {
            restartAutoHideTimer()
            return
        }
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0 else {
            restartAutoHideTimer()
            return
        }
        // Cap the bitmap resolution instead of allocating a full 4x iPad page.
        let renderScale = min(scale, 4096 / (max(size.width, size.height) * image.scale))
        renderPage(indexPath.item, in: imageView, size: CGSize(
            width: size.width * renderScale,
            height: size.height * renderScale
        ))
        restartAutoHideTimer()
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: pageCollectionView)
        guard let indexPath = pageCollectionView.indexPathForItem(at: point),
              let cell = pageCollectionView.cellForItem(at: indexPath) else { return }
        guard let scrollView = cell.contentView.viewWithTag(302) as? UIScrollView,
              let imageView = cell.contentView.viewWithTag(301) as? UIImageView else {
            preconditionFailure("PageCell is missing its zoom scroll view or image.")
        }
        autoHideTimer?.invalidate()
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let center = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2, height: scrollView.bounds.height / 2)
            scrollView.zoom(to: CGRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2,
                width: size.width, height: size.height
            ), animated: true)
        }
    }

    @objc private func toggleControls() {
        setControlsVisible(!controlsVisible || UIAccessibility.isVoiceOverRunning, animated: true)
    }

    private func setControlsVisible(_ visible: Bool, animated: Bool) {
        controlsVisible = visible
        topBarView.isUserInteractionEnabled = visible
        topBarView.accessibilityElementsHidden = !visible
        UIView.animate(
            withDuration: animated ? 0.2 : 0,
            delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.topBarView.alpha = visible ? 1 : 0
        }
        restartAutoHideTimer()
    }

    private func restartAutoHideTimer() {
        autoHideTimer?.invalidate()
        guard controlsVisible, previousIdleTimerSetting != nil,
              !UIAccessibility.isVoiceOverRunning,
              UIApplication.shared.applicationState == .active else { return }
        autoHideTimer = Timer.scheduledTimer(
            timeInterval: 10, target: self, selector: #selector(hideControlsAfterInactivity(_:)),
            userInfo: nil, repeats: false
        )
    }

    @objc private func hideControlsAfterInactivity(_ timer: Timer) {
        setControlsVisible(false, animated: true)
    }

    @objc private func readerWillResignActive(_ notification: Notification) {
        autoHideTimer?.invalidate()
        if let previousIdleTimerSetting {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
        }
    }

    @objc private func readerDidBecomeActive(_ notification: Notification) {
        guard previousIdleTimerSetting != nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        restartAutoHideTimer()
    }

    @objc private func voiceOverStatusChanged(_ notification: Notification) {
        if UIAccessibility.isVoiceOverRunning {
            setControlsVisible(true, animated: true)
        } else {
            restartAutoHideTimer()
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
    }

    private func displayError(message: String) {
        print(message)
        if isBeingPresented, let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.displayError(message: message)
            }
            return
        }
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Viewer Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
