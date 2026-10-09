//
//  FileBrowser+Selection.swift
//  Oblivion
//
import UIKit

extension FileBrowser {
    @IBAction func beginSelection(_ sender: UIBarButtonItem) {
        setSelectionMode(true)
    }

    @IBAction func selectAllItems(_ sender: UIBarButtonItem) {
        for index in currentDirectoryContent.indices {
            fileCollectionView.selectItem(at: IndexPath(item: index, section: 0), animated: false, scrollPosition: [])
        }
        selectedURLs = Set(currentDirectoryContent.map(\.url))
        updateSelection()
    }

    @IBAction func finishSelection(_ sender: UIBarButtonItem) {
        setSelectionMode(false)
        presentPendingImport()
    }

    @IBAction func deleteSelectedItems(_ sender: UIBarButtonItem) {
        let urls = currentDirectoryContent.map(\.url).filter { selectedURLs.contains($0) }
        confirmDeletion(of: urls, from: self) { [weak self] succeeded in
            if succeeded {
                self?.setSelectionMode(false)
                self?.presentPendingImport()
            }
        }
    }

    @IBAction func moveSelectedItem(_ sender: UIBarButtonItem) {
        guard selectedURLs.count == 1, let url = selectedURLs.first else { return }
        presentMove(for: url, from: self) { [weak self] succeeded in
            guard let self, succeeded, let currentDirectoryURL else { return }
            setSelectionMode(false)
            Task { _ = await self.refreshDirectory(at: currentDirectoryURL) }
        }
    }

    @IBAction func renameSelectedItem(_ sender: UIBarButtonItem) {
        guard selectedURLs.count == 1, let url = selectedURLs.first else { return }
        presentRename(of: url, from: self) { [weak self] renamedURL in
            if renamedURL != nil { self?.setSelectionMode(false) }
        }
    }

    func setSelectionMode(_ selecting: Bool) {
        self.selecting = selecting
        selectedURLs.removeAll()
        for indexPath in fileCollectionView.indexPathsForSelectedItems ?? [] {
            fileCollectionView.deselectItem(at: indexPath, animated: false)
        }
        fileCollectionView.allowsMultipleSelection = selecting
        breadcrumbCollectionView.isUserInteractionEnabled = !selecting
        backButton.isEnabled = !selecting && !directoryStack.isEmpty
        navigationItem.leftBarButtonItems = [selecting ? selectAllButton : backButton]
        navigationItem.rightBarButtonItems = selecting ? [doneButton] : [newDirectoryButton, selectButton]
        navigationController?.setToolbarHidden(!selecting, animated: !UIAccessibility.isReduceMotionEnabled)
        updateSelection()
    }

    func updateSelection() {
        deleteButton.isEnabled = !selectedURLs.isEmpty
        renameButton.isEnabled = selectedURLs.count == 1
        moveButton.isEnabled = selectedURLs.count == 1
        if selecting {
            title = "\(selectedURLs.count) Selected"
        } else if let currentDirectoryURL {
            title = directoryName(for: currentDirectoryURL)
        }
        for indexPath in fileCollectionView.indexPathsForVisibleItems {
            if let cell = fileCollectionView.cellForItem(at: indexPath) {
                configureSelection(for: cell, at: indexPath)
            }
        }
    }

    func configureSelection(for cell: UICollectionViewCell, at indexPath: IndexPath) {
        guard let indicator = cell.contentView.viewWithTag(104) as? UIImageView else {
            preconditionFailure("BrowserItemCell requires a selection indicator with tag 104.")
        }
        let item = currentDirectoryContent[indexPath.item]
        let selected = selectedURLs.contains(item.url)
        indicator.isHidden = !selecting
        indicator.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = selected ? .systemBlue.withAlphaComponent(0.12) : .clear
        cell.backgroundConfiguration = background
        cell.isAccessibilityElement = true
        let kind: String
        switch item {
        case .directory: kind = "Directory"
        case .file: kind = "File"
        }
        cell.accessibilityLabel = "\(item.url.lastPathComponent), \(kind)"
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
    }
}
