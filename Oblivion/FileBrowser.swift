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

    @IBAction func goToParentDirectory(_ sender: UIBarButtonItem) {
        guard let previousURL = directoryStack.last else { return }
        Task { [weak self] in
            guard let self else { return }
            if await setCurrentDirectory(at: previousURL) {
                directoryStack.removeLast()
            }
        }
    }

    @IBAction func beginSelection(_ sender: UIBarButtonItem) {
        setSelectionMode(true)
    }

    @IBAction func selectAllItems(_ sender: UIBarButtonItem) {
        for index in currentDirectoryContent.indices {
            fileCollectionView.selectItem(at: IndexPath(item: index, section: 0), animated: false, scrollPosition: [])
        }
        selectedURLs = Set(currentDirectoryContent.map(\.url))
        updateSelection()
    }

    @IBAction func finishSelection(_ sender: UIBarButtonItem) {
        setSelectionMode(false)
        presentPendingImport()
    }

    @IBAction func deleteSelectedItems(_ sender: UIBarButtonItem) {
        let urls = currentDirectoryContent.map(\.url).filter { selectedURLs.contains($0) }
        confirmDeletion(of: urls, from: self) { [weak self] succeeded in
            if succeeded {
                self?.setSelectionMode(false)
                self?.presentPendingImport()
            }
        }
    }

    private func confirmDeletion(of urls: [URL], from presenter: UIViewController, completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty else { return }
        let targets: [(url: URL, identifier: NSObject)]
        do {
            targets = try urls.map { url in
                guard let identifier = try url.resourceValues(forKeys: [.fileResourceIdentifierKey])
                    .fileResourceIdentifier as? NSObject else {
                    throw FileOperationError.invalidPath(url)
                }
                return (url, identifier)
            }
        } catch {
            displayError(message: "Could not verify the selected items: \(error.localizedDescription)", in: presenter)
            completion(false)
            return
        }
        let directoryNote = urls.contains { FileManager.default.isDirectory(atPath: $0.path) }
            ? " Directories and their contents will also be deleted." : ""
        let alert = UIAlertController(
            title: "Delete \(urls.count) \(urls.count == 1 ? "Item" : "Items")?",
            message: "This cannot be undone.\(directoryNote)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                completion(false)
                self?.presentPendingImport()
            }
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                Task { await self?.deleteItems(targets, from: presenter, completion: completion) }
            }
        })
        presenter.present(alert, animated: true)
    }

    @IBAction func unwindToBrowserFromViewer(_ segue: UIStoryboardSegue) {
        viewer = nil
    }

    private let fileSystemManager = FileSystemManager()
    private var currentDirectoryURL: URL?
    private var viewer: Viewer?
    private let thumbnails = NSCache<NSURL, UIImage>()
    private var thumbnailTasks: [URL: Task<Void, Never>] = [:]
    private var openingTask: Task<Void, Never>?
    private var initialDirectoryTask: Task<Void, Never>?
    private var directoryRequestID = UUID()
    private var selecting = false
    private var selectedURLs: Set<URL> = []
    var currentDirectoryContent: [DirectoryItem] = []
    var directoryStack: [URL] = [] {
        didSet {
            backButton?.isEnabled = !selecting && !directoryStack.isEmpty
            reloadBreadcrumbs()
        }
    }

    private var breadcrumbURLs: [URL] {
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

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === breadcrumbCollectionView ? breadcrumbURLs.count : currentDirectoryContent.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === breadcrumbCollectionView {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "BreadcrumbCell", for: indexPath)
            guard let nameLabel = cell.contentView.viewWithTag(201) as? UILabel,
                  let separatorLabel = cell.contentView.viewWithTag(202) as? UILabel else {
                preconditionFailure("BreadcrumbCell requires a name (201) and separator (202).")
            }
            let url = breadcrumbURLs[indexPath.item]
            let isCurrent = indexPath.item == breadcrumbURLs.count - 1
            nameLabel.text = directoryName(for: url)
            nameLabel.textColor = isCurrent ? .secondaryLabel : .systemBlue
            separatorLabel.isHidden = isCurrent
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = nameLabel.text
            cell.accessibilityTraits = isCurrent ? [.staticText, .selected] : .button
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "BrowserItemCell", for: indexPath)
        guard let imageView = cell.contentView.viewWithTag(101) as? UIImageView,
              let nameLabel = cell.contentView.viewWithTag(102) as? UILabel,
              let detailLabel = cell.contentView.viewWithTag(103) as? UILabel else {
            preconditionFailure("BrowserItemCell must contain an image (101), name (102), and detail (103).")
        }
        imageView.image = nil
        detailLabel.text = nil
        switch currentDirectoryContent[indexPath.item] {
        case let .directory(url):
            nameLabel.text = url.lastPathComponent
            detailLabel.text = "Directory"
            if let image = thumbnails.object(forKey: url as NSURL) {
                imageView.image = image
            } else {
                requestThumbnail(for: url, directory: true)
            }
        case let .file(url):
            nameLabel.text = url.lastPathComponent
            detailLabel.text = url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
            if let image = thumbnails.object(forKey: url as NSURL) {
                imageView.image = image
            } else {
                requestThumbnail(for: url)
            }
        }
        configureSelection(for: cell, at: indexPath)
        return cell
    }

    private func requestThumbnail(for url: URL, directory: Bool = false) {
        guard thumbnailTasks[url] == nil else { return }
        thumbnailTasks[url] = Task { [weak self] in
            let result = directory
                ? await Viewer.directoryIcon()
                : await Viewer.thumbnail(for: url, size: CGSize(width: 90, height: 124))
            guard !Task.isCancelled, let self else { return }
            thumbnailTasks[url] = nil
            if case let .success(image) = result {
                thumbnails.setObject(image, forKey: url as NSURL)
            }
            if case let .failure(error) = result {
                print("Could not preview \(url.lastPathComponent): \(error.localizedDescription)")
            }
            guard let index = currentDirectoryContent.firstIndex(where: { $0.url == url }),
                  let cell = fileCollectionView.cellForItem(at: IndexPath(item: index, section: 0)) else { return }
            guard let image = cell.contentView.viewWithTag(101) as? UIImageView,
                  let detail = cell.contentView.viewWithTag(103) as? UILabel else {
                preconditionFailure("BrowserItemCell requires image and detail views.")
            }
            switch result {
            case let .success(preview): image.image = preview
            case .failure: detail.text = directory ? "Icon unavailable" : "Preview unavailable"
            }
        }
    }

    deinit {
        for task in thumbnailTasks.values { task.cancel() }
        openingTask?.cancel()
        initialDirectoryTask?.cancel()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === fileCollectionView, selecting {
            selectedURLs.insert(currentDirectoryContent[indexPath.item].url)
            updateSelection()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        if collectionView === breadcrumbCollectionView {
            guard indexPath.item < directoryStack.count else { return }
            let url = breadcrumbURLs[indexPath.item]
            let previousStack = Array(directoryStack.prefix(indexPath.item))
            Task { [weak self] in
                guard let self else { return }
                if await setCurrentDirectory(at: url) {
                    directoryStack = previousStack
                }
            }
            return
        }
        switch currentDirectoryContent[indexPath.item] {
        case let .directory(url):
            let previousURL = currentDirectoryURL
            Task { [weak self] in
                guard let self else { return }
                if await setCurrentDirectory(at: url), let previousURL {
                    directoryStack.append(previousURL)
                }
            }
        case let .file(url):
            openingTask?.cancel()
            openingTask = Task { [weak self] in
                let result = await Viewer.loadDocument(at: url)
                guard !Task.isCancelled, let self else { return }
                openingTask = nil
                guard viewIfLoaded?.window != nil, presentedViewController == nil,
                      currentDirectoryContent.contains(where: { $0.url == url }) else { return }
                switch result {
                case let .success(document):
                    performSegue(withIdentifier: "ShowViewer", sender: document)
                case let .failure(error):
                    displayError(message: error.localizedDescription)
                }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard collectionView === fileCollectionView, selecting else { return }
        selectedURLs.remove(currentDirectoryContent[indexPath.item].url)
        updateSelection()
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if collectionView === breadcrumbCollectionView { return !selecting }
        return !selecting || !fileSystemManager.isProtectedPath(at: currentDirectoryContent[indexPath.item].url)
    }

    private func setSelectionMode(_ selecting: Bool) {
        self.selecting = selecting
        selectedURLs.removeAll()
        for indexPath in fileCollectionView.indexPathsForSelectedItems ?? [] {
            fileCollectionView.deselectItem(at: indexPath, animated: false)
        }
        fileCollectionView.allowsMultipleSelection = selecting
        breadcrumbCollectionView.isUserInteractionEnabled = !selecting
        backButton.isEnabled = !selecting && !directoryStack.isEmpty
        navigationItem.leftBarButtonItems = [selecting ? selectAllButton : backButton]
        navigationItem.rightBarButtonItems = selecting ? [doneButton] : [newDirectoryButton, selectButton]
        navigationController?.setToolbarHidden(!selecting, animated: !UIAccessibility.isReduceMotionEnabled)
        updateSelection()
    }

    private func updateSelection() {
        deleteButton.isEnabled = !selectedURLs.isEmpty
        deleteButton.title = selectedURLs.isEmpty ? "Delete" : "Delete (\(selectedURLs.count))"
        if selecting {
            title = "\(selectedURLs.count) Selected"
        } else if let currentDirectoryURL {
            title = directoryName(for: currentDirectoryURL)
        }
        for indexPath in fileCollectionView.indexPathsForVisibleItems {
            if let cell = fileCollectionView.cellForItem(at: indexPath) {
                configureSelection(for: cell, at: indexPath)
            }
        }
    }

    private func configureSelection(for cell: UICollectionViewCell, at indexPath: IndexPath) {
        guard let indicator = cell.contentView.viewWithTag(104) as? UIImageView else {
            preconditionFailure("BrowserItemCell requires a selection indicator with tag 104.")
        }
        let item = currentDirectoryContent[indexPath.item]
        let selected = selectedURLs.contains(item.url)
        indicator.isHidden = !selecting
        indicator.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = selected ? .systemBlue.withAlphaComponent(0.12) : .clear
        cell.backgroundConfiguration = background
        cell.isAccessibilityElement = true
        let kind: String
        switch item {
        case .directory: kind = "Directory"
        case .file: kind = "File"
        }
        cell.accessibilityLabel = "\(item.url.lastPathComponent), \(kind)"
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    @IBAction func createDirectory(_ sender: UIBarButtonItem) {
        guard let parentURL = currentDirectoryURL else {
            displayError(message: "No current directory is available.")
            return
        }
        let alert = UIAlertController(title: "New Directory", message: "Enter a directory name.", preferredStyle: .alert)
        alert.addTextField { $0.configureForDirectoryName() }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) { self?.presentPendingImport() }
        })
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            alert?.dismiss(animated: true) {
                Task {
                    guard let self else { return }
                    switch self.fileSystemManager.createDir(named: name, in: parentURL) {
                    case .success:
                        _ = await self.refreshDirectory(at: parentURL)
                        self.presentPendingImport()
                    case let .failure(error):
                        self.displayError(message: error.localizedDescription)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func deleteItems(_ targets: [(url: URL, identifier: NSObject)], from presenter: UIViewController, completion: @escaping (Bool) -> Void) async {
        guard let currentDirectoryURL else {
            displayError(message: "No current directory is available.", in: presenter)
            completion(false)
            return
        }
        var failures: [String] = []
        for (url, identifier) in targets {
            switch fileSystemManager.deleteFile(path: url, matching: identifier) {
            case .success:
                selectedURLs.remove(url)
                currentDirectoryContent.removeAll { $0.url == url }
            case let .failure(error):
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if presenter === self || !failures.isEmpty {
            if !(await refreshDirectory(at: currentDirectoryURL, errorPresenter: presenter)) { reloadFiles() }
        }
        if failures.isEmpty {
            completion(true)
        } else {
            displayError(message: failures.joined(separator: "\n"), in: presenter)
            completion(false)
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)
        if segue.identifier == "ShowImport" {
            guard let sourceURL = sender as? URL,
                  let navigation = segue.destination as? UINavigationController,
                  let handler = navigation.viewControllers.first as? ImportHandler else {
                preconditionFailure("ShowImport must receive a file URL and present ImportHandler.")
            }
            handler.sourceURL = sourceURL
            handler.initialDirectoryURL = currentDirectoryURL
            handler.directoryStack = directoryStack
            handler.onDismiss = { [weak self] _ in
                self?.importDidDismiss()
            }
            return
        }
        guard segue.identifier == "ShowViewer" else { return }
        guard let document = sender as? Viewer.Document,
              let viewer = segue.destination as? Viewer else {
            preconditionFailure("ShowViewer must receive a document and present Viewer.")
        }
        viewer.document = document
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        viewer.onMove = { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            self.presentMove(for: document.url, from: viewer)
        }
        viewer.onDelete = { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            self.confirmDeletion(of: [document.url], from: viewer) { [weak self, weak viewer] succeeded in
                guard let viewer else { return }
                if succeeded {
                    self?.closeViewer(viewer)
                } else {
                    viewer.restartAutoHideTimer()
                }
            }
        }
        self.viewer = viewer
    }

    private func presentMove(for url: URL, from viewer: Viewer) {
        guard let navigation = storyboard?.instantiateViewController(withIdentifier: "ImportHandlerNavigationController") as? UINavigationController,
              let handler = navigation.viewControllers.first as? ImportHandler else {
            preconditionFailure("Move must use the existing import destination scene.")
        }
        handler.operation = .move
        handler.sourceURL = url
        handler.initialDirectoryURL = url.deletingLastPathComponent()
        handler.directoryStack = directoryStack
        handler.onDismiss = { [weak self, weak viewer] succeeded in
            guard let viewer else { return }
            if succeeded {
                self?.closeViewer(viewer)
            } else {
                viewer.restartAutoHideTimer()
            }
        }
        viewer.present(navigation, animated: true)
    }

    private func closeViewer(_ viewer: Viewer) {
        viewer.dismiss(animated: true) { [weak self] in
            self?.viewer = nil
            self?.importDidDismiss()
        }
    }

    func showImport(for url: URL) -> Bool {
        guard currentDirectoryURL != nil else {
            print("Cannot show import while the initial directory is loading.")
            return false
        }
        guard viewIfLoaded?.window != nil,
              presentedViewController == nil,
              navigationController?.presentedViewController == nil else {
            print("Cannot show import while the browser is hidden or another popup is open.")
            return false
        }
        guard Viewer.supportsFile(at: url) else {
            displayError(message: "This file type is not supported. Choose a PDF or a supported image.")
            return false
        }
        if selecting { setSelectionMode(false) }
        performSegue(withIdentifier: "ShowImport", sender: url)
        return true
    }

    private func importDidDismiss() {
        Task { [weak self] in
            guard let self else { return }
            if let currentDirectoryURL {
                _ = await refreshDirectory(at: currentDirectoryURL)
            }
            presentPendingImport()
        }
    }

    private func presentPendingImport() {
        (view.window?.windowScene?.delegate as? SceneDelegate)?.presentPendingImport()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else {
            preconditionFailure("FileBrowser collections require flow layouts.")
        }
        guard collectionView === breadcrumbCollectionView else { return layout.itemSize }
        let name = directoryName(for: breadcrumbURLs[indexPath.item])
        let width = (name as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14)]).width
        return CGSize(width: ceil(width) + 36, height: collectionView.bounds.height)
    }

    private func directoryName(for url: URL) -> String {
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
            applyDirectoryContents(items)
            return true
        case let .failure(error):
            displayError(message: "Could not load the directory: \(error.localizedDescription)", in: errorPresenter)
            return false
        }
    }

    private func applyDirectoryContents(_ items: [DirectoryItem]) {
        openingTask?.cancel()
        openingTask = nil
        currentDirectoryContent = items
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        thumbnails.removeAllObjects()
        selectedURLs.formIntersection(Set(items.map(\.url)))
        reloadFiles()
    }

    private func reloadFiles() {
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
        if UIAccessibility.isReduceMotionEnabled {
            changes()
        } else {
            UIView.transition(with: fileCollectionView, duration: 0.2,
                              options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)
        }
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

extension UITextField {
    func configureForDirectoryName() {
        placeholder = "Directory name"
        autocorrectionType = .no
        spellCheckingType = .no
    }
}
