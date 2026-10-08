//
//  ImportHandler.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import UIKit
import UniformTypeIdentifiers

class ImportHandler: UIViewController, UITableViewDataSource, UITableViewDelegate, UIAdaptivePresentationControllerDelegate {
    private let fileSystemManager = FileSystemManager()
    private var thumbnailTask: Task<Void, Never>?
    private var directoryRequestID = UUID()
    private var directoryTask: Task<Void, Never>?
    private var directoryIconTask: Task<Void, Never>?
    private var directoryIcon: UIImage?
    var sourceURL: URL? {
        didSet { fileName = sourceURL?.lastPathComponent ?? "" }
    }
    var fileName = "" {
        didSet { fileNameLabel?.text = fileName }
    }
    var initialDirectoryURL: URL?
    var operation: FileTransferOperation = .copy
    var onDismiss: ((Bool) -> Void)?
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
    @IBOutlet weak var confirmButton: UIBarButtonItem!
    @IBOutlet weak var destinationPromptLabel: UILabel!
    @IBOutlet weak var helperLabel: UILabel!
    @IBOutlet weak var renameButton: UIButton!
    
    @IBAction func cancelImport(_ sender: UIBarButtonItem) {
        directoryTask?.cancel()
        dismiss(animated: true) { self.onDismiss?(false) }
    }
    
    @IBAction func confirmImport(_ sender: UIBarButtonItem) {
        guard let sourceURL else {
            displayError(message: "No file selected.")
            return
        }

        if handle(url: sourceURL) {
            dismiss(animated: true) { self.onDismiss?(true) }
        }
    }

    @IBAction func renameFile(_ sender: UIButton) {
        guard let sourceURL else { return }
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { [fileName] in $0.configureForRename(fileName, selecting: (fileName as NSString).deletingPathExtension) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let name = fileSystemManager.resolvedName(alert?.textFields?.first?.text ?? "", for: sourceURL) else {
                displayError(message: FileOperationError.invalidName.localizedDescription)
                return
            }
            fileName = name
        })
        present(alert, animated: true)
    }

    @IBAction func createDir(_ sender: UIBarButtonItem) {
        let alert = UIAlertController(
            title: "New Directory",
            message: "Enter a directory name.",
            preferredStyle: .alert
        )
        alert.addTextField { $0.configureForDirectoryName() }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let directoryName = alert.textFields?.first?.text ?? ""
            guard let parentURL = self.currentDirectoryURL else {
                self.displayError(message: "Could not get the current directory.")
                return
            }
            switch self.fileSystemManager.createDir(named: directoryName, in: parentURL) {
            case .success:
                Task { _ = await self.refreshDirectory(at: parentURL) }
            case let .failure(error):
                self.displayError(message: "Could not create the directory: \(error.localizedDescription)")
            }
        })
        present(alert, animated: true)
    }

    @IBAction func goBack(_ sender: UIButton) {
        guard let parentURL = directoryStack.last else { return }
        directoryTask?.cancel()
        directoryTask = Task { [weak self] in
            guard let self else { return }
            if await setCurrentDirectory(at: parentURL) {
                directoryStack.removeLast()
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = operation == .copy ? "Import File" : "Move File"
        confirmButton.title = operation == .copy ? "Import" : "Move"
        destinationPromptLabel.text = operation == .copy ? "SAVE A COPY TO" : "MOVE TO"
        helperLabel.text = operation == .copy
            ? "Choose a directory, or import here.\nThe original file stays in its source location."
            : "Choose a different directory.\nThe file will be moved, not copied."
        fileNameLabel.text = sourceURL == nil ? "No file selected" : fileName
        renameButton.isHidden = operation == .move
        updateDestinationLabels()
        directoryIconTask = Task { [weak self] in
            let result = await Viewer.directoryIcon()
            guard !Task.isCancelled, let self else { return }
            switch result {
            case let .success(image):
                directoryIcon = image
                directoryTableView.reloadData()
            case let .failure(error):
                print("Could not load the Directory icon: \(error.localizedDescription)")
            }
        }
        guard let sourceURL else { return }
        fileDetailLabel.text = UTType(filenameExtension: sourceURL.pathExtension)?.localizedDescription ?? "Document"
        thumbnailTask = Task { [weak self] in
            let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            let result = await Viewer.thumbnail(for: sourceURL, size: CGSize(width: 44, height: 56))
            guard !Task.isCancelled, let self else { return }
            switch result {
            case let .success(image):
                fileImageView.image = image
            case let .failure(error):
                fileDetailLabel.text = "Preview unavailable"
                print("Could not preview \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    deinit {
        thumbnailTask?.cancel()
        directoryTask?.cancel()
        directoryIconTask?.cancel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
        guard currentDirectoryURL == nil else { return }
        guard let currentURL = initialDirectoryURL ?? fileSystemManager.documentsDirectory else {
            displayError(message: "The Documents directory is unavailable.")
            return
        }
        directoryTask = Task { [weak self] in
            _ = await self?.setCurrentDirectory(at: currentURL)
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss?(false)
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
            content.image = directoryIcon
            content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
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
            directoryTask?.cancel()
            directoryTask = Task { [weak self] in
                guard let self else { return }
                if await setCurrentDirectory(at: url), let previousURL {
                    directoryStack.append(previousURL)
                }
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

        switch fileSystemManager.transferFile(path: url, dst: destination.appendingPathComponent(fileName), operation: operation) {
        case .success: return true
        case let .failure(.fileAlreadyExists(existingURL)):
            displayError(message: "An item named \(existingURL.lastPathComponent) already exists in this directory.")
            return false
        case let .failure(error):
            displayError(message: "Could not \(operation == .copy ? "import" : "move") the file: \(error.localizedDescription)")
            return false
        }
    }
    
    func refreshDirectory(at url: URL) async -> Bool {
        let identifier = UUID()
        directoryRequestID = identifier
        directoryTableView.isUserInteractionEnabled = false
        confirmButton.isEnabled = false
        backButton.isEnabled = false
        defer {
            if directoryRequestID == identifier {
                directoryTableView.isUserInteractionEnabled = true
                updateDestinationLabels()
            }
        }
        let listDirectoryResult = await FileSystemManager.readDirectory(at: url)
        guard !Task.isCancelled, directoryRequestID == identifier,
              viewIfLoaded?.window != nil else { return false }
        switch listDirectoryResult {
        case let .success(items):
            currentDirectoryContent = items.filter {
                if case .directory = $0 { return true }
                return false
            }
            if UIAccessibility.isReduceMotionEnabled {
                directoryTableView.reloadData()
            } else {
                UIView.transition(with: directoryTableView, duration: 0.2,
                                  options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
                    self.directoryTableView.reloadData()
                })
            }
            return true
        case let .failure(error):
            displayError(message: "Could not load the directory: \(error.localizedDescription)")
            return false
        }
    }

    func setCurrentDirectory(at url: URL?) async -> Bool {
        guard let url else {
            displayError(message: "No directory was provided.")
            return false
        }
        if !(await refreshDirectory(at: url)) {
            return false
        }

        currentDirectoryURL = url
        updateDestinationLabels()
        return true
    }

    private func updateDestinationLabels() {
        guard isViewLoaded else { return }
        backButton.isEnabled = !directoryStack.isEmpty
        confirmButton.isEnabled = false
        guard let currentDirectoryURL else { return }
        confirmButton.isEnabled = operation == .copy ||
            currentDirectoryURL.resolvingSymlinksInPath().standardizedFileURL != sourceURL?.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = fileSystemManager.documentsDirectory
        let name = currentDirectoryURL == root ? "Home" : currentDirectoryURL.lastPathComponent
        destinationNameLabel.text = name
        destinationPathLabel.text = (directoryStack + [currentDirectoryURL]).map {
            $0 == root ? "Home" : $0.lastPathComponent
        }.joined(separator: " › ")
        defaultBadgeLabel.isHidden = operation == .move || currentDirectoryURL != (initialDirectoryURL ?? root)
        toolbarDestinationLabel.text = "\(operation == .copy ? "Import" : "Move") into \(name)"
    }
    
    func displayError(message: String) {
        print(message)
        let alert = UIAlertController(title: operation == .copy ? "Import Error" : "Move Error", message: message, preferredStyle: .alert)
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
