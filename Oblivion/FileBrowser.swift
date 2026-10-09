//
//  FileBrowser.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-07.
//
import UIKit

class FileBrowser: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    @IBOutlet weak var fileCollectionView: UICollectionView!
    @IBOutlet weak var breadcrumbCollectionView: UICollectionView!
    @IBOutlet weak var itemCountLabel: UILabel!
    // Retain navigation items while they are swapped out of the navigation bar.
    @IBOutlet var backButton: UIBarButtonItem!
    @IBOutlet var selectAllButton: UIBarButtonItem!
    @IBOutlet var newDirectoryButton: UIBarButtonItem!
    @IBOutlet var selectButton: UIBarButtonItem!
    @IBOutlet var doneButton: UIBarButtonItem!
    @IBOutlet weak var deleteButton: UIBarButtonItem!
    @IBOutlet weak var renameButton: UIBarButtonItem!
    @IBOutlet weak var moveButton: UIBarButtonItem!

    @IBAction func goToParentDirectory(_ sender: UIBarButtonItem) {
        guard let previousURL = directoryStack.last else { return }
        Task { [weak self] in
            guard let self else { return }
            if await setCurrentDirectory(at: previousURL) {
                directoryStack.removeLast()
            }
        }
    }

    @IBAction func unwindToBrowserFromViewer(_ segue: UIStoryboardSegue) {
        viewer = nil
    }

    let fileSystemManager = FileSystemManager()
    var currentDirectoryURL: URL?
    var viewer: Viewer?
    let thumbnails = NSCache<NSURL, UIImage>()
    var itemCounts: [URL: Int] = [:]
    private var slideAnimator: UIViewPropertyAnimator?
    var thumbnailTasks: [URL: Task<Void, Never>] = [:]
    var openingTask: Task<Void, Never>?
    private var initialDirectoryTask: Task<Void, Never>?
    private var directoryRequestID = UUID()
    var selecting = false
    var selectedURLs: Set<URL> = []
    var currentDirectoryContent: [DirectoryItem] = []
    var directoryStack: [URL] = [] {
        didSet {
            backButton?.isEnabled = !selecting && !directoryStack.isEmpty
            reloadBreadcrumbs()
        }
    }

    var breadcrumbURLs: [URL] {
        guard let currentDirectoryURL else { return [] }
        return directoryStack + [currentDirectoryURL]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backButton.isEnabled = false
        navigationController?.setToolbarHidden(true, animated: false)
        navigationItem.leftBarButtonItems = [backButton]
        navigationItem.rightBarButtonItems = [newDirectoryButton, selectButton]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if currentDirectoryURL == nil {
            guard initialDirectoryTask == nil else { return }
            guard let documentsURL = fileSystemManager.documentsDirectory else {
                displayError(message: "The Documents directory is unavailable.")
                return
            }
            title = "Home"
            initialDirectoryTask = Task { [weak self] in
                guard let self else { return }
                let succeeded = await setCurrentDirectory(at: documentsURL)
                guard !Task.isCancelled else { return }
                initialDirectoryTask = nil
                if succeeded { presentPendingImport() }
            }
            return
        }
        fileCollectionView.reloadData()
        presentPendingImport()
    }

    deinit {
        for task in thumbnailTasks.values { task.cancel() }
        openingTask?.cancel()
        initialDirectoryTask?.cancel()
    }

    func presentPendingImport() {
        (view.window?.windowScene?.delegate as? SceneDelegate)?.presentPendingImport()
    }

    func directoryName(for url: URL) -> String {
        url == fileSystemManager.documentsDirectory ? "Home" : url.lastPathComponent
    }

    private func reloadBreadcrumbs() {
        guard isViewLoaded else { return }
        breadcrumbCollectionView.reloadData()
        guard !breadcrumbURLs.isEmpty else { return }
        breadcrumbCollectionView.layoutIfNeeded()
        breadcrumbCollectionView.scrollToItem(
            at: IndexPath(item: breadcrumbURLs.count - 1, section: 0),
            at: .right, animated: false
        )
    }

    func refreshDirectory(at url: URL, errorPresenter: UIViewController? = nil) async -> Bool {
        let identifier = UUID()
        directoryRequestID = identifier
        openingTask?.cancel()
        openingTask = nil
        fileCollectionView.isUserInteractionEnabled = false
        breadcrumbCollectionView.isUserInteractionEnabled = false
        newDirectoryButton.isEnabled = false
        selectButton.isEnabled = false
        backButton.isEnabled = false
        defer {
            if directoryRequestID == identifier {
                fileCollectionView.isUserInteractionEnabled = true
                breadcrumbCollectionView.isUserInteractionEnabled = !selecting
                newDirectoryButton.isEnabled = currentDirectoryURL != nil
                selectButton.isEnabled = currentDirectoryURL != nil
                backButton.isEnabled = !selecting && !directoryStack.isEmpty
            }
        }
        let result = await FileSystemManager.readDirectory(at: url)
        guard !Task.isCancelled, directoryRequestID == identifier else { return false }
        switch result {
        case let .success(items):
            let forward = currentDirectoryURL.map { url.pathComponents.count > $0.pathComponents.count }
            applyDirectoryContents(items, slidingForward: url == currentDirectoryURL ? nil : forward)
            return true
        case let .failure(error):
            displayError(message: "Could not load the directory: \(error.localizedDescription)", in: errorPresenter)
            return false
        }
    }

    private func applyDirectoryContents(_ items: [DirectoryItem], slidingForward forward: Bool? = nil) {
        openingTask?.cancel()
        openingTask = nil
        currentDirectoryContent = items
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        thumbnails.removeAllObjects()
        itemCounts.removeAll()
        selectedURLs.formIntersection(Set(items.map(\.url)))
        reloadFiles(slidingForward: forward)
    }

    func reloadFiles(slidingForward forward: Bool? = nil) {
        let changes = {
            self.fileCollectionView.reloadData()
            self.fileCollectionView.layoutIfNeeded()
            for (index, item) in self.currentDirectoryContent.enumerated() where self.selectedURLs.contains(item.url) {
                self.fileCollectionView.selectItem(at: IndexPath(item: index, section: 0), animated: false, scrollPosition: [])
            }
            let count = self.currentDirectoryContent.count
            self.itemCountLabel.text = "\(count) \(count == 1 ? "item" : "items")"
            self.updateSelection()
        }
        // Files keeps its navigation slide even with Reduce Motion on.
        if let forward {
            slide(forward: forward, changes: changes)
        } else if UIAccessibility.isReduceMotionEnabled {
            changes()
        } else {
            UIView.transition(with: fileCollectionView, duration: 0.2,
                              options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)
        }
    }

    // Mirrors a navigation push/pop: the top layer slides a full width, the lower one a third.
    private func slide(forward: Bool, changes: () -> Void) {
        slideAnimator?.stopAnimation(false)
        slideAnimator?.finishAnimation(at: .end)
        guard let container = fileCollectionView.superview,
              let snapshot = fileCollectionView.snapshotView(afterScreenUpdates: false) else { return changes() }
        snapshot.frame = fileCollectionView.frame
        snapshot.backgroundColor = fileCollectionView.backgroundColor
        if forward {
            container.insertSubview(snapshot, belowSubview: fileCollectionView)
        } else {
            container.insertSubview(snapshot, aboveSubview: fileCollectionView)
        }
        changes()
        let width = fileCollectionView.bounds.width
        fileCollectionView.transform = CGAffineTransform(translationX: forward ? width : -width / 3, y: 0)
        let animator = UIViewPropertyAnimator(duration: 0.4, dampingRatio: 1) {
            self.fileCollectionView.transform = .identity
            snapshot.transform = CGAffineTransform(translationX: forward ? -width / 3 : width, y: 0)
        }
        animator.addCompletion { _ in snapshot.removeFromSuperview() }
        slideAnimator = animator
        animator.startAnimation()
    }

    func setCurrentDirectory(at url: URL?) async -> Bool {
        guard let url else {
            displayError(message: "No directory was provided.")
            return false
        }
        guard await refreshDirectory(at: url) else { return false }
        currentDirectoryURL = url
        newDirectoryButton.isEnabled = true
        selectButton.isEnabled = true
        title = directoryName(for: url)
        reloadBreadcrumbs()
        return true
    }

    func displayError(message: String, in presenter: UIViewController? = nil) {
        let presenter = presenter ?? self
        print(message)
        if let alert = presenter.presentedViewController as? UIAlertController {
            alert.message = [alert.message, message].compactMap { $0 }.joined(separator: "\n")
            return
        }
        let alert = UIAlertController(title: "File Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                self?.presentPendingImport()
                (presenter as? Viewer)?.restartAutoHideTimer()
            }
        })
        presenter.present(alert, animated: true)
    }
}
