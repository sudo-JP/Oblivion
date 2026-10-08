//
//  FileBrowser.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-07.
//
import UIKit

class FileBrowser: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
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
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backButton.isEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard currentDirectoryURL == nil else { return }
        guard let documentsURL = fileSystemManager.documentsDirectory else {
            displayError(message: "The Documents directory is unavailable.")
            return
        }
        _ = setCurrentDirectory(at: documentsURL)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        currentDirectoryContent.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
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
        guard segue.identifier == "ShowViewer" else { return }
        guard let document = sender as? Viewer.Document,
              let viewer = segue.destination as? Viewer else {
            preconditionFailure("ShowViewer must receive a document and present Viewer.")
        }
        viewer.document = document
        self.viewer = viewer
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
        title = url == fileSystemManager.documentsDirectory ? "Home" : url.lastPathComponent
        breadcrumbCollectionView.reloadData()
        return true
    }

    func displayError(message: String) {
        let alert = UIAlertController(title: "File Browser Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
