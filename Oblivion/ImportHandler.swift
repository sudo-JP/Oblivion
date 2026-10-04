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
    
    @IBAction func cancelImport(_ sender: UIBarButtonItem) {
        dismiss(animated: true)
    }
    
    @IBAction func confirmImport(_ sender: UIBarButtonItem) {
        // TODO: Read destinationPathLabel.text and implement the import.
    }

    @IBAction func createDir(_ sender: UIBarButtonItem) {
        // TODO: Implement folder creation.
    }

    @IBAction func goBack(_ sender: UIButton) {
        if directoryStack.isEmpty {
            return
        }
        guard let parentURL = directoryStack.popLast() else {
            return
        }
        
        let listDirectoryResult = fileSystemManager.listDirectory(at: parentURL)
        guard case let .success(items) = listDirectoryResult else {
            return
        }
        currentDirectoryURL = parentURL
        currentDirectoryContent = items
        directoryTableView.reloadData()
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
            let listDirectoryResult = fileSystemManager.listDirectory(at: url)
            guard case let .success(items) = listDirectoryResult else {
                return
            }

            currentDirectoryURL = url
            currentDirectoryContent = items
            directoryStack.append(url)
            tableView.reloadData()
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

}
