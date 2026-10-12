//
//  FileBrowser+Reader.swift
//  Oblivion
//
import UIKit

extension FileBrowser {
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
        viewer.onRename = { [weak self, weak viewer] in
            guard let self, let viewer, let url = viewer.document?.url else { return }
            self.presentRename(of: url, from: viewer) { [weak viewer] renamedURL in
                if let renamedURL { viewer?.rename(to: renamedURL) }
                viewer?.restartAutoHideTimer()
            }
        }
        viewer.onMove = { [weak self, weak viewer] in
            guard let self, let viewer, let url = viewer.document?.url else { return }
            self.presentMove(for: url, from: viewer) { [weak self, weak viewer] succeeded in
                guard let viewer else { return }
                if succeeded {
                    self?.closeViewer(viewer)
                } else {
                    viewer.restartAutoHideTimer()
                }
            }
        }
        viewer.onDelete = { [weak self, weak viewer] in
            guard let self, let viewer, let url = viewer.document?.url else { return }
            self.confirmDeletion(of: [url], from: viewer) { [weak self, weak viewer] succeeded in
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
}
