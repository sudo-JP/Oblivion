//
//  FileBrowser+Alerts.swift
//  Oblivion
//
import UIKit

extension FileBrowser {
    func presentRename(of url: URL, from presenter: UIViewController, completion: @escaping (URL?) -> Void) {
        let name = url.lastPathComponent
        let baseName = FileManager.default.isDirectory(atPath: url.path) ? name : url.deletingPathExtension().lastPathComponent
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.configureForRename(name, selecting: baseName) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                completion(nil)
                self?.presentPendingImport()
            }
        })
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            let newName = alert?.textFields?.first?.text ?? ""
            alert?.dismiss(animated: true) { self?.rename(url, to: newName, from: presenter, completion: completion) }
        })
        presenter.present(alert, animated: true)
    }

    func rename(_ url: URL, to name: String, from presenter: UIViewController, completion: @escaping (URL?) -> Void) {
        switch fileSystemManager.renameItem(at: url, to: name) {
        case let .success(renamedURL):
            Task {
                if let currentDirectoryURL { _ = await refreshDirectory(at: currentDirectoryURL, errorPresenter: presenter) }
                completion(renamedURL)
                presentPendingImport()
            }
        case let .failure(error):
            displayError(message: "Could not rename \(url.lastPathComponent): \(error.localizedDescription)", in: presenter)
            completion(nil)
        }
    }

    func confirmDeletion(of urls: [URL], from presenter: UIViewController, completion: @escaping (Bool) -> Void) {
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

    func presentMove(for url: URL, from presenter: UIViewController, completion: @escaping (Bool) -> Void) {
        guard let navigation = storyboard?.instantiateViewController(withIdentifier: "ImportHandlerNavigationController") as? UINavigationController,
              let handler = navigation.viewControllers.first as? ImportHandler else {
            preconditionFailure("Move must use the existing import destination scene.")
        }
        handler.operation = .move
        handler.sourceURL = url
        handler.initialDirectoryURL = url.deletingLastPathComponent()
        handler.directoryStack = directoryStack
        handler.onDismiss = completion
        presenter.present(navigation, animated: true)
    }
}

extension UITextField {
    func configureForDirectoryName() {
        placeholder = "Directory name"
        autocorrectionType = .no
        spellCheckingType = .no
    }

    func configureForRename(_ name: String, selecting baseName: String) {
        text = name
        autocorrectionType = .no
        spellCheckingType = .no
        clearButtonMode = .whileEditing
        addAction(UIAction { action in
            guard let field = action.sender as? UITextField,
                  let end = field.position(from: field.beginningOfDocument, offset: baseName.utf16.count) else { return }
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: end)
        }, for: .editingDidBegin)
    }
}
