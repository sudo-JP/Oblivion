//
//  FileBrowser.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-07.
//
import UIKit
import UniformTypeIdentifiers

class FileBrowser: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                   UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    @IBOutlet weak var fileCollectionView: UICollectionView!
    @IBOutlet weak var breadcrumbCollectionView: UICollectionView!
    @IBOutlet weak var backButton: UIBarButtonItem!
    @IBOutlet weak var itemCountLabel: UILabel!

    @IBAction func goToParentDirectory(_ sender: UIBarButtonItem) {
        guard let previousURL = directoryStack.last else { return }
        if setCurrentDirectory(at: previousURL) {
            directoryStack.removeLast()
        }
    }

    @IBAction func importFile(_ sender: UIBarButtonItem) {
        guard presentedViewController == nil,
              navigationController?.presentedViewController == nil else {
            print("Cannot open the file picker while another popup is open.")
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .image], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    @IBAction func unwindToBrowserFromViewer(_ segue: UIStoryboardSegue) {
        viewer = nil
    }

    private let fileSystemManager = FileSystemManager()
    private var currentDirectoryURL: URL?
    private var viewer: Viewer?
    private let thumbnails = NSCache<NSURL, UIImage>()
    var currentDirectoryContent: [DirectoryItem] = []
    var directoryStack: [URL] = [] {
        didSet {
            backButton?.isEnabled = !directoryStack.isEmpty
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if currentDirectoryURL == nil {
            guard let documentsURL = fileSystemManager.documentsDirectory else {
                displayError(message: "The Documents directory is unavailable.")
                return
            }
            _ = setCurrentDirectory(at: documentsURL)
        }
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
            imageView.image = UIImage(systemName: "folder")
            imageView.tintColor = .systemBlue
            detailLabel.text = "Folder"
        case let .file(url):
            nameLabel.text = url.lastPathComponent
            detailLabel.text = url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
            if let image = thumbnails.object(forKey: url as NSURL) {
                imageView.image = image
            } else {
                switch Viewer.thumbnail(for: url, size: CGSize(width: 90, height: 124)) {
                case let .success(image):
                    thumbnails.setObject(image, forKey: url as NSURL)
                    imageView.image = image
                case let .failure(error):
                    detailLabel.text = "Preview unavailable"
                    print("Could not preview \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if collectionView === breadcrumbCollectionView {
            guard indexPath.item < directoryStack.count else { return }
            let url = breadcrumbURLs[indexPath.item]
            let previousStack = Array(directoryStack.prefix(indexPath.item))
            if setCurrentDirectory(at: url) {
                directoryStack = previousStack
            }
            return
        }
        switch currentDirectoryContent[indexPath.item] {
        case let .directory(url):
            let previousURL = currentDirectoryURL
            if setCurrentDirectory(at: url), let previousURL {
                directoryStack.append(previousURL)
            }
        case let .file(url):
            switch Viewer.loadDocument(at: url) {
            case let .success(document):
                performSegue(withIdentifier: "ShowViewer", sender: document)
            case let .failure(error):
                displayError(message: error.localizedDescription)
            }
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
            handler.onDismiss = { [weak self] in
                self?.importDidDismiss()
            }
            navigation.presentationController?.delegate = self
            return
        }
        guard segue.identifier == "ShowViewer" else { return }
        guard let document = sender as? Viewer.Document,
              let viewer = segue.destination as? Viewer else {
            preconditionFailure("ShowViewer must receive a document and present Viewer.")
        }
        viewer.document = document
        self.viewer = viewer
    }

    func showImport(for url: URL) -> Bool {
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
        performSegue(withIdentifier: "ShowImport", sender: url)
        return true
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            guard let url = urls.first else {
                self.displayError(message: "The file picker did not return a file.")
                return
            }
            _ = self.showImport(for: url)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true) { [weak self] in
            self?.presentPendingImport()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        importDidDismiss()
    }

    private func importDidDismiss() {
        if let currentDirectoryURL {
            _ = refreshDirectory(at: currentDirectoryURL)
        }
        presentPendingImport()
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

    func refreshDirectory(at url: URL) -> Bool {
        switch fileSystemManager.listDirectory(at: url) {
        case let .success(items):
            currentDirectoryContent = items
            thumbnails.removeAllObjects()
            fileCollectionView.reloadData()
            itemCountLabel.text = "\(items.count) \(items.count == 1 ? "item" : "items")"
            return true
        case let .failure(error):
            displayError(message: "Could not load the directory: \(error)")
            return false
        }
    }

    func setCurrentDirectory(at url: URL?) -> Bool {
        guard let url else {
            displayError(message: "No directory was provided.")
            return false
        }
        guard refreshDirectory(at: url) else { return false }
        currentDirectoryURL = url
        title = directoryName(for: url)
        reloadBreadcrumbs()
        return true
    }

    func displayError(message: String) {
        let alert = UIAlertController(title: "File Browser Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                self?.presentPendingImport()
            }
        })
        present(alert, animated: true)
    }
}
