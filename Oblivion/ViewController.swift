//
//  ViewController.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//

import UIKit
import UniformTypeIdentifiers

class ViewController: UIViewController, UIDocumentPickerDelegate {
    @IBAction func unwindToBrowserFromViewer(_ segue: UIStoryboardSegue) {
        
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (view.window?.windowScene?.delegate as? SceneDelegate)?.presentPendingImport()
    }

    @discardableResult
    func showImport(for url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
            print("Cannot import this file: only PDF files are currently supported.")
            return false
        }
        guard viewIfLoaded?.window != nil,
              presentedViewController == nil,
              navigationController?.presentedViewController == nil else {
            print("Cannot show import while the browser is hidden or another popup is open.")
            return false
        }
        performSegue(withIdentifier: "ShowImport", sender: url)
        return true
    }

    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {
        guard identifier == "ShowImport" else { return true }
        guard presentedViewController == nil,
              navigationController?.presentedViewController == nil else {
            print("Cannot open the file picker while another popup is open.")
            return false
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
        return false
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)
        guard segue.identifier == "ShowImport" else { return }
        guard let sourceURL = sender as? URL,
              let navigation = segue.destination as? UINavigationController,
              let handler = navigation.viewControllers.first as? ImportHandler else {
            preconditionFailure("ShowImport must receive a file URL and present ImportHandler.")
        }
        handler.sourceURL = sourceURL
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            print("The document picker did not return a file.")
            return
        }
        controller.dismiss(animated: true) { [weak self] in
            self?.showImport(for: url)
        }
    }
}
