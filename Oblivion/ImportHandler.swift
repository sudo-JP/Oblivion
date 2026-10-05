//
//  ImportHandler.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import UIKit

class ImportHandler: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let fileSystemManager = FileSystemManager()
    var sourceURL: URL?
    var currentDirectoryURL: URL?
    var currentDirectoryContent: [DirectoryItem] = []
    var directoryStack: [URL] = []
    
    @IBOutlet weak var fileNameLabel: UILabel!
    @IBOutlet weak var directoryTableView: UITableView!
    @IBOutlet weak var errorMessageView: UIStackView!
    @IBOutlet weak var errorMessageLabel: UILabel!

    @IBAction func closeErrorMessage(_ sender: UIButton) {
        errorMessageView.isHidden = true
    }
    
    @IBAction func cancelImport(_ sender: UIBarButtonItem) {
        dismiss(animated: true)
    }
    
    @IBAction func confirmImport(_ sender: UIBarButtonItem) {
        guard let sourceURL else {
            displayError(message: "No file selected.")
            return
        }

        if handle(url: sourceURL) {
            dismiss(animated: true)
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
        fileNameLabel.text = sourceURL?.lastPathComponent ?? "No file selected"
        guard let currentURL = fileSystemManager.documentsDirectory else {
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
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
            displayError(message: "Only PDF files are currently supported.")
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

    func setCurrentDirectory(at url: URL) -> Bool {
        if !refreshDirectory(at: url) {
            return false
        }

        currentDirectoryURL = url
        return true
    }
    
    func displayError(message: String) {
        errorMessageLabel.text = message
        errorMessageView.isHidden = false

    }

}
