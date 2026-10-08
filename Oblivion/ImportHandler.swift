//
//  ImportHandler.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import UIKit
import UniformTypeIdentifiers

class ImportHandler: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let fileSystemManager = FileSystemManager()
    var sourceURL: URL?
    var initialDirectoryURL: URL?
    var onDismiss: (() -> Void)?
    var currentDirectoryURL: URL?
    var currentDirectoryContent: [DirectoryItem] = []
    var directoryStack: [URL] = [] {
        didSet { updateDestinationLabels() }
    }
    
    @IBOutlet weak var fileNameLabel: UILabel!
    @IBOutlet weak var directoryTableView: UITableView!
    @IBOutlet weak var fileImageView: UIImageView!
    @IBOutlet weak var fileDetailLabel: UILabel!
    @IBOutlet weak var destinationNameLabel: UILabel!
    @IBOutlet weak var destinationPathLabel: UILabel!
    @IBOutlet weak var defaultBadgeLabel: UILabel!
    @IBOutlet weak var toolbarDestinationLabel: UILabel!
    @IBOutlet weak var backButton: UIButton!
    
    @IBAction func cancelImport(_ sender: UIBarButtonItem) {
        dismiss(animated: true, completion: onDismiss)
    }
    
    @IBAction func confirmImport(_ sender: UIBarButtonItem) {
        guard let sourceURL else {
            displayError(message: "No file selected.")
            return
        }

        if handle(url: sourceURL) {
            dismiss(animated: true, completion: onDismiss)
        }
    }

    @IBAction func createDir(_ sender: UIBarButtonItem) {
        let alert = UIAlertController(
            title: "New Directory",
            message: "Enter a directory name.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "Directory name"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let directoryName = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if directoryName.isEmpty ||
                directoryName == "." || directoryName == ".." ||
                directoryName.contains("/") || directoryName.contains("\0") {
                self.displayError(message: "Enter a valid directory name without slashes.")
                return
            }
            guard let parentURL = self.currentDirectoryURL else {
                self.displayError(message: "Could not get the current directory.")
                return
            }
            let newDirectoryURL = parentURL.appendingPathComponent(
                directoryName,
                isDirectory: true
            )

            guard !FileManager.default.fileExists(atPath: newDirectoryURL.path) else {
                self.displayError(message: "An item with that name already exists.")
                return
            }
            switch self.fileSystemManager.createDir(at: newDirectoryURL) {
            case .success:
                _ = self.refreshDirectory(at: parentURL)
            case let .failure(error):
                self.displayError(message: "Could not create the directory: \(error)")
            }
        })
        present(alert, animated: true)
    }

    @IBAction func goBack(_ sender: UIButton) {
        guard let parentURL = directoryStack.last else { return }
        if setCurrentDirectory(at: parentURL) {
            directoryStack.removeLast()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Import File"
        fileNameLabel.text = sourceURL?.lastPathComponent ?? "No file selected"
        updateDestinationLabels()
        guard let sourceURL else { return }
        fileDetailLabel.text = UTType(filenameExtension: sourceURL.pathExtension)?.localizedDescription ?? "Document"
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        switch Viewer.thumbnail(for: sourceURL, size: CGSize(width: 44, height: 56)) {
        case let .success(image):
            fileImageView.image = image
        case let .failure(error):
            fileDetailLabel.text = "Preview unavailable"
            print("Could not preview \(sourceURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard currentDirectoryURL == nil else { return }
        guard let currentURL = initialDirectoryURL ?? fileSystemManager.documentsDirectory else {
            displayError(message: "The Documents directory is unavailable.")
            return
        }
        _ = setCurrentDirectory(at: currentURL)
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        currentDirectoryContent.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FolderCell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let fileContent = currentDirectoryContent[indexPath.row]
        
        switch fileContent {
        case let .directory(url):
            content.text = url.lastPathComponent
            content.image = UIImage(systemName: "folder")
        case let .file(url):
            content.text = url.lastPathComponent
            content.image = UIImage(systemName: "doc.fill")
        }
        cell.contentConfiguration = content
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let fileContent = currentDirectoryContent[indexPath.row]
        switch fileContent {
        case let .directory(url):
            let previousURL = currentDirectoryURL
            if setCurrentDirectory(at: url), let previousURL {
                directoryStack.append(previousURL)
            }
        case .file:
            break
        }
    }
        
    public func handle(url: URL) -> Bool {
        guard Viewer.supportsFile(at: url) else {
            displayError(message: "This file type is not supported. Choose a PDF or a supported image.")
            return false
        }
            
        let hasScopedAccess = url.startAccessingSecurityScopedResource()

        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let destination = currentDirectoryURL ?? fileSystemManager.documentsDirectory
        guard let destination else {
            displayError(message: "No destination directory is available.")
            return false
        }

        switch fileSystemManager.copyFile(path: url, dst: destination.appendingPathComponent(url.lastPathComponent)) {
        case .success: return true
        case let .failure(.fileAlreadyExists(existingURL)):
            displayError(message: "An item named \(existingURL.lastPathComponent) already exists in this directory.")
            return false
        case let .failure(error):
            displayError(message: "Could not import the file: \(error)")
            return false
        }
    }
    
    func refreshDirectory(at url: URL) -> Bool {
        let listDirectoryResult = fileSystemManager.listDirectory(at: url)
        switch listDirectoryResult {
        case let .success(items):
            currentDirectoryContent = items.filter {
                if case .directory = $0 { return true }
                return false
            }
            directoryTableView.reloadData()
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
        if !refreshDirectory(at: url) {
            return false
        }

        currentDirectoryURL = url
        updateDestinationLabels()
        return true
    }

    private func updateDestinationLabels() {
        guard isViewLoaded else { return }
        backButton.isEnabled = !directoryStack.isEmpty
        guard let currentDirectoryURL else { return }
        let root = fileSystemManager.documentsDirectory
        let name = currentDirectoryURL == root ? "Home" : currentDirectoryURL.lastPathComponent
        destinationNameLabel.text = name
        destinationPathLabel.text = (directoryStack + [currentDirectoryURL]).map {
            $0 == root ? "Home" : $0.lastPathComponent
        }.joined(separator: " › ")
        defaultBadgeLabel.isHidden = currentDirectoryURL != (initialDirectoryURL ?? root)
        toolbarDestinationLabel.text = "Import into \(name)"
    }
    
    func displayError(message: String) {
        let alert = UIAlertController(title: "Import Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        if let presentedViewController {
            presentedViewController.dismiss(animated: true) { [weak self] in
                self?.present(alert, animated: true)
            }
        } else {
            present(alert, animated: true)
        }
    }

}
