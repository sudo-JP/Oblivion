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

class Viewer: UIViewController {
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
    var onMove: (() -> Void)?
    var onDelete: (() -> Void)?
    private var lastContentSize = CGSize.zero
    private var controlsVisible = true
    private var autoHideTimer: Timer?
    private var previousIdleTimerSetting: Bool?

    @IBOutlet weak var contentContainer: UIView!

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
            do {
                // Documents is the app's container root, which Quick Look renders as the app icon on device.
                try FileManager.default.createDirectory(at: directoryIconURL, withIntermediateDirectories: true)
            } catch {
                return Result<UIImage, ViewerError>.failure(.thumbnailGeneration(error.localizedDescription))
            }
            return await generatePreview(for: directoryIconURL, size: CGSize(width: 90, height: 90), types: .icon)
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
        let content = document.content.contentView
        content.frame = contentContainer.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.addSubview(content)
        document.content.onPageChange = { [weak self] _ in self?.restartAutoHideTimer() }

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        contentContainer.addGestureRecognizer(singleTap)
        contentContainer.addGestureRecognizer(doubleTap)

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
}
