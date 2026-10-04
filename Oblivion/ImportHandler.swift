//
//  ImportHandler.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import UIKit

class ImportHandler: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let fileSystemManager = FileSystemManager()
    var currentDirectoryURL: URL?
    var documentsDirectory: URL?
    var currentDirectoryContent: [DirectoryItem] = []
    var directoryStack: [URL] = []
    
    @IBOutlet weak var destinationPathLabel: UILabel!
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
        // TODO: Read destinationPathLabel.text and implement the import.
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
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            let directoryName = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let invalidCharacters = [".", "..", "/"]
            if directoryName.isEmpty ||
                invalidCharacters.contains(where: { directoryName.contains($0) }) {
                self?.displayError(message: "Could not create the directory.")
                return
            }
            guard let parentURL = self?.currentDirectoryURL else {
                self?.displayError(message: "Could not get parent directory path")
                return
            }
            let newDirectoryURL = parentURL.appendingPathComponent(
                directoryName,
                isDirectory: true
            )

            guard case .success() = self?.fileSystemManager.createDir(at: newDirectoryURL) else {
                self?.displayError(message: "Could not create the directory.")
                return
            }
        })
        present(alert, animated: true)

    }

    @IBAction func goBack(_ sender: UIButton) {
        if directoryStack.isEmpty {
            return
        }
        guard let parentURL = directoryStack.popLast() else {
            return
        }
        
        if !setCurrentDirectory(at: parentURL) {
            return
        }
    }
    
    override func viewDidLoad() {
        guard let currentURL = fileSystemManager.documentsDirectory else {
            return
        }
        currentDirectoryURL = currentURL
        if !setCurrentDirectory(at: currentURL) {
            return
        }
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
        let fileContent = currentDirectoryContent[indexPath.row]
        switch fileContent {
        case let .directory(url):
            if !setCurrentDirectory(at: url) {
                return
            }
        case let .file(url):
            // TODO PDFViewer
        }
    }
        
    public func handle(url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else { return false }
            
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to get security-scoped access to the file.")
            return false
        }
            
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        let destination = currentDirectoryURL ?? fileSystemManager.documentsDirectory
        guard let destination else { return false }

        switch fileSystemManager.moveFile(path: url, dst: destination.appendingPathComponent(url.lastPathComponent)) {
        case .success: return true
        case .failure: return false
        }
    }
    
    func setCurrentDirectory(at url: URL) -> Bool {
        let listDirectoryResult = fileSystemManager.listDirectory(at: url)
        guard case let .success(items) = listDirectoryResult else {
            return false
        }

        currentDirectoryURL = url
        currentDirectoryContent = items
        directoryStack.append(url)
        directoryTableView.reloadData()
        return true
    }
    
    func displayError(message: String) {
        errorMessageLabel.text = message
        errorMessageView.isHidden = false

    }

}
