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
            case .InvalidSize:
                return "The requested preview size is invalid."
            case .Cancelled:
                return "Document rendering was cancelled."
            }
        }
    }
}

class Viewer: UIViewController, UIGestureRecognizerDelegate {
    struct Document {
        let url: URL
        let content: any Viewable
    }

    private static let openersByExtension: [String: (URL) async -> Result<any Viewable, ViewerError>] = [
        "pdf": PDFViewer.open,
        "jpg": ImageViewer.open,
        "jpeg": ImageViewer.open,
        "png": ImageViewer.open,
        "heic": ImageViewer.open,
        "heif": ImageViewer.open,
        "gif": ImageViewer.open,
        "bmp": ImageViewer.open,
        "tif": ImageViewer.open,
        "tiff": ImageViewer.open,
        "webp": ImageViewer.open
    ]
    // Cancellation crosses actors; keep non-Sendable Quick Look requests on the UI actor.
    private static var thumbnailRequests: [UUID: QLThumbnailGenerator.Request] = [:]
    private static var directoryIconTask: Task<Result<UIImage, ViewerError>, Never>?

    var document: Document?
    var onRename: (() -> Void)?
    var onMove: (() -> Void)?
    var onDelete: (() -> Void)?
    private var lastContentSize = CGSize.zero
    private var controlsVisible = true
    private var autoHideTimer: Timer?
    private var previousIdleTimerSetting: Bool?

    @IBOutlet weak var contentContainer: UIView!
    @IBOutlet weak var pageIndicator: UIView!
    @IBOutlet weak var pageIndicatorLabel: UILabel!

    override var prefersStatusBarHidden: Bool { !controlsVisible }
    override var prefersHomeIndicatorAutoHidden: Bool { !controlsVisible }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    @IBOutlet weak var topBarView: UIView!
    
    @IBOutlet weak var fileNameLabel: UILabel!
    
    @IBAction func showDocumentActions(_ sender: UIButton) {
        guard let onRename, let onMove, let onDelete else {
            preconditionFailure("FileBrowser must supply the reader's Rename, Move and Delete actions.")
        }
        autoHideTimer?.invalidate()
        let alert = UIAlertController(title: document?.url.lastPathComponent, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak alert] _ in
            alert?.dismiss(animated: true, completion: onRename)
        })
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

    func rename(to url: URL) {
        guard let content = document?.content else { return }
        document = Document(url: url, content: content)
        fileNameLabel.text = url.lastPathComponent
    }

    static func loadDocument(at url: URL) async -> Result<Document, ViewerError> {
        guard url.isFileURL else { return .failure(.cannotOpen(url)) }
        let fileExtension = url.pathExtension.lowercased()
        guard let open = openersByExtension[fileExtension] else {
            return .failure(.unsupportedExtension(fileExtension))
        }
        return await open(url).flatMap { content in
            content.pageCount > 0 ? .success(Document(url: url, content: content)) : .failure(.noPages)
        }
    }

    static func supportsFile(at url: URL) -> Bool {
        url.isFileURL && openersByExtension[url.pathExtension.lowercased()] != nil
    }

    static func thumbnail(for url: URL, size: CGSize) async -> Result<UIImage, ViewerError> {
        guard url.isFileURL else { return .failure(.cannotOpen(url)) }
        guard supportsFile(at: url) else { return .failure(.unsupportedExtension(url.pathExtension)) }
        return await generatePreview(for: url, size: size, types: .thumbnail)
    }

    static let directoryIconURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DirectoryIcon", isDirectory: true)

    static func directoryIcon() async -> Result<UIImage, ViewerError> {
        if let directoryIconTask { return await directoryIconTask.value }
        let task = Task {
            // Before iOS 26, Quick Look returns blank or generic page icons for directories on device.
            guard #available(iOS 26, *) else { return Result<UIImage, ViewerError>.success(drawnDirectoryIcon) }
            do {
                // Documents is the app's container root, which Quick Look renders as the app icon on device.
                try FileManager.default.createDirectory(at: directoryIconURL, withIntermediateDirectories: true)
            } catch {
                print("Could not prepare the Directory icon probe: \(error.localizedDescription)")
                return Result<UIImage, ViewerError>.success(drawnDirectoryIcon)
            }
            if case let .success(icon) = await generatePreview(for: directoryIconURL, size: CGSize(width: 90, height: 90), types: .icon),
               hasVisibleContent(icon) {
                return .success(icon)
            }
            return .success(drawnDirectoryIcon)
        }
        directoryIconTask = task
        return await task.value
    }

    // Replica of the iOS 18 Files Directory icon, measured on its 528-pixel canvas.
    static let drawnDirectoryIcon = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 90)).image { context in
        let scale = 90.0 / 528
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        let back = UIBezierPath()
        back.move(to: point(0, 300))
        back.addLine(to: point(0, 88))
        back.addQuadCurve(to: point(30, 58), controlPoint: point(0, 58))
        back.addLine(to: point(140, 58))
        back.addCurve(to: point(205, 104), controlPoint1: point(166, 58), controlPoint2: point(174, 104))
        back.addLine(to: point(500, 104))
        back.addQuadCurve(to: point(528, 132), controlPoint: point(528, 104))
        back.addLine(to: point(528, 300))
        back.close()
        UIColor(red: 0.612, green: 0.882, blue: 0.996, alpha: 1).setFill()
        back.fill()
        let front = CGRect(x: 0, y: 137 * scale, width: 90, height: 333 * scale)
        UIBezierPath(roundedRect: front, cornerRadius: 26 * scale).addClip()
        let colors = [UIColor(red: 0.482, green: 0.820, blue: 0.969, alpha: 1).cgColor,
                      UIColor(red: 0.573, green: 0.859, blue: 0.988, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: front.minY), end: CGPoint(x: 0, y: front.maxY), options: [])
        }
        UIColor(red: 0.63, green: 0.886, blue: 0.988, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: front.minY, width: 90, height: 1.5 * scale))
    }

    static func hasVisibleContent(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        return drawn && stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
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
        let content = document.content.contentView
        content.frame = contentContainer.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.addSubview(content)
        showPage(document.content.currentPage)
        document.content.onPageChange = { [weak self] page in
            self?.showPage(page)
            self?.restartAutoHideTimer()
        }

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        contentContainer.addGestureRecognizer(singleTap)
        contentContainer.addGestureRecognizer(doubleTap)
        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        contentContainer.addGestureRecognizer(dismissPan)

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
        let size = contentContainer.bounds.size
        guard size.width > 0, size.height > 0, size != lastContentSize, let document else { return }
        lastContentSize = size
        document.content.fitToView()
        restartAutoHideTimer()
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        autoHideTimer?.invalidate()
        document?.content.toggleZoom(at: gesture.location(in: document?.content.contentView))
        restartAutoHideTimer()
    }

    static func beginsDismissal(velocity: CGPoint, isZoomed: Bool) -> Bool {
        !isZoomed && velocity.y > abs(velocity.x)
    }

    static func completesDismissal(translation: CGFloat, velocity: CGFloat, height: CGFloat) -> Bool {
        translation > height * 0.25 || velocity > 800
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let document else { return true }
        return Self.beginsDismissal(velocity: pan.velocity(in: view), isZoomed: document.content.isZoomed)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let height = view.bounds.height
        let translation = pan.translation(in: view)
        let progress = min(max(translation.y, 0) / height, 1)
        switch pan.state {
        case .began:
            setControlsVisible(false, animated: true)
        case .changed:
            let scale = 1 - 0.25 * progress
            contentContainer.transform = CGAffineTransform(translationX: translation.x, y: max(translation.y, 0))
                .scaledBy(x: scale, y: scale)
            view.backgroundColor = .black.withAlphaComponent(1 - progress)
        case .ended where Self.completesDismissal(
            translation: translation.y, velocity: pan.velocity(in: view).y, height: height
        ):
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: 0.25, animations: {
                if reduceMotion {
                    self.view.alpha = 0
                } else {
                    self.contentContainer.transform = self.contentContainer.transform
                        .concatenating(CGAffineTransform(translationX: 0, y: height))
                }
                self.view.backgroundColor = .clear
            }, completion: { _ in
                self.performSegue(withIdentifier: "DismissViewer", sender: self)
            })
        default:
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.contentContainer.transform = .identity
                self.view.backgroundColor = .black
            }
        }
    }

    @objc func toggleControls() {
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
            self.pageIndicator.alpha = visible ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        restartAutoHideTimer()
    }

    private func showPage(_ page: Int) {
        guard let document else { return }
        pageIndicatorLabel.text = "\(page + 1) / \(document.content.pageCount)"
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
}
