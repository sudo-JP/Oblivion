//
//  ImportHandler.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import UIKit

class ImportHandler: UIViewController {
    private let fileSystemManager = FileSystemManager()
    var selectedDirectoryURL: URL?
    var documentsDirectory: URL?
    
    @IBOutlet weak var destinationPathLabel: UILabel!
    
    @IBAction func cancelImport(_ sender: UIBarButtonItem) {
        dismiss(animated: true)
    }
    
    @IBAction func confirmImport(_ sender: UIBarButtonItem) {
        // TODO: Read destinationPathLabel.text and implement the import.
    }

    @IBAction func newFolder(_ sender: UIBarButtonItem) {
        // TODO: Implement folder creation.
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
        let destination = selectedDirectoryURL ?? fileSystemManager.documentsDirectory
        guard let destination else { return false }

        switch fileSystemManager.moveFile(path: url, dst: destination.appendingPathComponent(url.lastPathComponent)) {
        case .success: return true
        case .failure: return false
        }
    }

}
