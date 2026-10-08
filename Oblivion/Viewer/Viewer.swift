//
//  Viewer.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import UIKit
import QuickLookThumbnailing

enum ViewerError: LocalizedError {
    case unsupportedExtension(String)
    case cannotOpen(URL)
    case noPages
    case rendering(RetrieveViewableError)
    case thumbnailGeneration(String)

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
        case let .thumbnailGeneration(message):
            return "Could not generate a preview: \(message)"
        case let .rendering(error):
            switch error {
            case .IndexOutOfRange:
                return "The requested document page is unavailable."
            case .InvalidSize:
                return "The requested preview size is invalid."
            case .InvalidPageBounds:
                return "This document page has invalid dimensions."
            case .CannotOpen:
                return "The document could not be loaded for rendering."
            case .Cancelled:
                return "Document rendering was cancelled."
            }
        }
    }
}

class Viewer: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    struct Document {
        let url: URL
        let content: any Viewable
        let pageCount: Int
    }

    private static let renderersByExtension: [String: (URL) -> any Viewable] = [
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
    // Cancellation crosses actors; keep non-Sendable Quick Look requests on the UI actor.
    private static var thumbnailRequests: [UUID: QLThumbnailGenerator.Request] = [:]
    private static var directoryIconTask: Task<Result<UIImage, ViewerError>, Never>?

    var document: Document?
    var onMove: (() -> Void)?
    var onDelete: (() -> Void)?
    var firstPagePreview: UIImage?
    private var currentPage = 0
    private var lastPageSize = CGSize.zero
    private var controlsVisible = true
    private var autoHideTimer: Timer?
    private var previousIdleTimerSetting: Bool?
    private let pageImages = NSCache<NSNumber, UIImage>()
    private var pageTasks: [Int: Task<Void, Never>] = [:]
    private var rotationID: UUID?

    @IBOutlet weak var pageCollectionView: UICollectionView!
    
    @IBOutlet weak var topBarView: UIView!
    
    @IBOutlet weak var fileNameLabel: UILabel!
    
    @IBAction func showDocumentActions(_ sender: UIButton) {
        guard let onMove, let onDelete else {
            preconditionFailure("FileBrowser must supply the reader's Move and Delete actions.")
        }
        autoHideTimer?.invalidate()
        let alert = UIAlertController(title: document?.url.lastPathComponent, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Move", style: .default) { [weak alert] _ in
            alert?.dismiss(animated: true, completion: onMove)
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak alert] _ in
            alert?.dismiss(animated: true, completion: onDelete)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) { self?.restartAutoHideTimer() }
        })
        alert.popoverPresentationController?.sourceView = sender
        alert.popoverPresentationController?.sourceRect = sender.bounds
        present(alert, animated: true)
    }

    static func loadDocument(at url: URL) async -> Result<Document, ViewerError> {
        guard url.isFileURL else { return .failure(.cannotOpen(url)) }
        let fileExtension = url.pathExtension.lowercased()
        guard let renderer = renderersByExtension[fileExtension] else {
            return .failure(.unsupportedExtension(fileExtension))
        }
        let content = renderer(url)
        switch await content.open() {
        case let .success(pageCount):
            guard pageCount > 0 else { return .failure(.noPages) }
            return .success(Document(url: url, content: content, pageCount: pageCount))
        case let .failure(error):
            return .failure(error)
        }
    }

    static func supportsFile(at url: URL) -> Bool {
        url.isFileURL && renderersByExtension[url.pathExtension.lowercased()] != nil
    }

    static func thumbnail(for url: URL, size: CGSize) async -> Result<UIImage, ViewerError> {
        guard url.isFileURL else { return .failure(.cannotOpen(url)) }
        guard supportsFile(at: url) else { return .failure(.unsupportedExtension(url.pathExtension)) }
        return await generatePreview(for: url, size: size, types: .thumbnail)
    }

    static func directoryIcon() async -> Result<UIImage, ViewerError> {
        if let directoryIconTask { return await directoryIconTask.value }
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return .failure(.thumbnailGeneration("The Documents directory is unavailable."))
        }
        let task = Task {
            await generatePreview(for: url, size: CGSize(width: 90, height: 90), types: .icon)
        }
        directoryIconTask = task
        return await task.value
    }

    private static func generatePreview(
        for url: URL, size: CGSize, types: QLThumbnailGenerator.Request.RepresentationTypes
    ) async -> Result<UIImage, ViewerError> {
        guard url.isFileURL else { return .failure(.cannotOpen(url)) }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .failure(.rendering(.InvalidSize))
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: UIScreen.main.scale, representationTypes: types)
        let identifier = UUID()
        thumbnailRequests[identifier] = request
        defer { thumbnailRequests[identifier] = nil }
        do {
            let preview = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                Task { await cancelThumbnail(identifier) }
            }
            return .success(preview.uiImage.withRenderingMode(.alwaysOriginal))
        } catch {
            return .failure(.thumbnailGeneration(error.localizedDescription))
        }
    }

    private static func cancelThumbnail(_ identifier: UUID) {
        if let request = thumbnailRequests[identifier] {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let document else {
            preconditionFailure("ShowViewer must supply a document before loading Viewer.")
        }
        fileNameLabel.text = document.url.lastPathComponent
        pageImages.countLimit = 3
        pageImages.totalCostLimit = 32 * 1024 * 1024
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
        guard let layout = pageCollectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            preconditionFailure("Viewer requires a flow layout.")
        }
        layout.itemSize = size
        pageCollectionView.setContentOffset(
            CGPoint(x: CGFloat(currentPage) * size.width, y: 0),
            animated: false
        )
        restartAutoHideTimer()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        updateCurrentPage()
        let identifier = UUID()
        rotationID = identifier
        for task in pageTasks.values { task.cancel() }
        pageTasks.removeAll()
        for cell in pageCollectionView.visibleCells {
            guard let zoom = cell.contentView.viewWithTag(302) as? UIScrollView else {
                preconditionFailure("PageCell requires its zoom scroll view.")
            }
            zoom.setZoomScale(zoom.minimumZoomScale, animated: false)
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, rotationID == identifier else { return }
            rotationID = nil
            pageCollectionView.layoutIfNeeded()
            for cell in pageCollectionView.visibleCells {
                guard let indexPath = pageCollectionView.indexPath(for: cell),
                      let image = cell.contentView.viewWithTag(301) as? UIImageView,
                      let zoom = cell.contentView.viewWithTag(302) as? UIScrollView else {
                    preconditionFailure("PageCell requires its page image and zoom scroll view.")
                }
                zoom.setZoomScale(zoom.minimumZoomScale, animated: false)
                renderPage(indexPath.item, in: image, size: zoom.bounds.size)
            }
        }
    }

    deinit {
        for task in pageTasks.values { task.cancel() }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let document else {
            preconditionFailure("Viewer requires a document.")
        }
        return document.pageCount
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
        imageView.image = indexPath.item == 0 ? firstPagePreview : nil
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
        if let image = pageImages.object(forKey: NSNumber(value: index)) {
            imageView.image = image
            if min(size.width / image.size.width, size.height / image.size.height) <= 1.01 { return }
        }
        guard rotationID == nil else { return }
        pageTasks[index]?.cancel()
        pageTasks[index] = Task { [weak self, weak imageView] in
            let result = await document.content.image(forPage: index, size: size)
            guard !Task.isCancelled, let self else { return }
            pageTasks[index] = nil
            guard let imageView,
                  pageCollectionView.cellForItem(at: IndexPath(item: index, section: 0))?
                    .contentView.viewWithTag(301) === imageView else { return }
            switch result {
            case let .success(image):
                let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
                pageImages.setObject(image, forKey: NSNumber(value: index), cost: cost)
                imageView.image = image
            case let .failure(error):
                displayError(message: ViewerError.rendering(error).localizedDescription)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        pageTasks.removeValue(forKey: indexPath.item)?.cancel()
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

    func restartAutoHideTimer() {
        autoHideTimer?.invalidate()
        guard controlsVisible, previousIdleTimerSetting != nil,
              presentedViewController == nil,
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
        currentPage = min(max(page, 0), document.pageCount - 1)
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
