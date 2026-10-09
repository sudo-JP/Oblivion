//
//  FileBrowser+Grid.swift
//  Oblivion
//
import UIKit

extension FileBrowser {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === breadcrumbCollectionView ? breadcrumbURLs.count : currentDirectoryContent.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === breadcrumbCollectionView {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "BreadcrumbCell", for: indexPath)
            guard let nameLabel = cell.contentView.viewWithTag(201) as? UILabel,
                  let separatorLabel = cell.contentView.viewWithTag(202) as? UILabel else {
                preconditionFailure("BreadcrumbCell requires a name (201) and separator (202).")
            }
            let url = breadcrumbURLs[indexPath.item]
            let isCurrent = indexPath.item == breadcrumbURLs.count - 1
            nameLabel.text = directoryName(for: url)
            nameLabel.textColor = isCurrent ? .secondaryLabel : .systemBlue
            separatorLabel.isHidden = isCurrent
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = nameLabel.text
            cell.accessibilityTraits = isCurrent ? [.staticText, .selected] : .button
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "BrowserItemCell", for: indexPath)
        guard let imageView = cell.contentView.viewWithTag(101) as? UIImageView,
              let nameLabel = cell.contentView.viewWithTag(102) as? UILabel,
              let detailLabel = cell.contentView.viewWithTag(103) as? UILabel else {
            preconditionFailure("BrowserItemCell must contain an image (101), name (102), and detail (103).")
        }
        imageView.image = nil
        detailLabel.text = nil
        switch currentDirectoryContent[indexPath.item] {
        case let .directory(url):
            nameLabel.text = url.lastPathComponent
            if let count = itemCounts[url] {
                detailLabel.text = "\(count) \(count == 1 ? "item" : "items")"
            }
            if let image = thumbnails.object(forKey: url as NSURL) {
                imageView.image = image
            } else {
                requestThumbnail(for: url, directory: true)
            }
        case let .file(url):
            nameLabel.text = url.lastPathComponent
            detailLabel.text = url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
            if let image = thumbnails.object(forKey: url as NSURL) {
                imageView.image = image
            } else {
                requestThumbnail(for: url)
            }
        }
        configureSelection(for: cell, at: indexPath)
        return cell
    }

    private func requestThumbnail(for url: URL, directory: Bool = false) {
        guard thumbnailTasks[url] == nil else { return }
        thumbnailTasks[url] = Task { [weak self] in
            let count = directory ? await FileSystemManager.readItemCount(at: url) : nil
            let result = directory
                ? await Viewer.directoryIcon()
                : await Viewer.thumbnail(for: url, size: CGSize(width: 90, height: 124))
            guard !Task.isCancelled, let self else { return }
            thumbnailTasks[url] = nil
            itemCounts[url] = count
            if case let .success(image) = result {
                thumbnails.setObject(image, forKey: url as NSURL)
            }
            if case let .failure(error) = result {
                print("Could not preview \(url.lastPathComponent): \(error.localizedDescription)")
            }
            guard let index = currentDirectoryContent.firstIndex(where: { $0.url == url }),
                  let cell = fileCollectionView.cellForItem(at: IndexPath(item: index, section: 0)) else { return }
            guard let image = cell.contentView.viewWithTag(101) as? UIImageView,
                  let detail = cell.contentView.viewWithTag(103) as? UILabel else {
                preconditionFailure("BrowserItemCell requires image and detail views.")
            }
            if let count { detail.text = "\(count) \(count == 1 ? "item" : "items")" }
            switch result {
            case let .success(preview): image.image = preview
            case .failure: detail.text = directory ? "Icon unavailable" : "Preview unavailable"
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === fileCollectionView, selecting {
            selectedURLs.insert(currentDirectoryContent[indexPath.item].url)
            updateSelection()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        if collectionView === breadcrumbCollectionView {
            guard indexPath.item < directoryStack.count else { return }
            let url = breadcrumbURLs[indexPath.item]
            let previousStack = Array(directoryStack.prefix(indexPath.item))
            Task { [weak self] in
                guard let self else { return }
                if await setCurrentDirectory(at: url) {
                    directoryStack = previousStack
                }
            }
            return
        }
        switch currentDirectoryContent[indexPath.item] {
        case let .directory(url):
            let previousURL = currentDirectoryURL
            Task { [weak self] in
                guard let self else { return }
                if await setCurrentDirectory(at: url), let previousURL {
                    directoryStack.append(previousURL)
                }
            }
        case let .file(url):
            openingTask?.cancel()
            openingTask = Task { [weak self] in
                let result = await Viewer.loadDocument(at: url)
                guard !Task.isCancelled, let self else { return }
                openingTask = nil
                guard viewIfLoaded?.window != nil, presentedViewController == nil,
                      currentDirectoryContent.contains(where: { $0.url == url }) else { return }
                switch result {
                case let .success(document):
                    performSegue(withIdentifier: "ShowViewer", sender: document)
                case let .failure(error):
                    displayError(message: error.localizedDescription)
                }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard collectionView === fileCollectionView, selecting else { return }
        selectedURLs.remove(currentDirectoryContent[indexPath.item].url)
        updateSelection()
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if collectionView === breadcrumbCollectionView { return !selecting }
        return !selecting || !fileSystemManager.isProtectedPath(at: currentDirectoryContent[indexPath.item].url)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else {
            preconditionFailure("FileBrowser collections require flow layouts.")
        }
        guard collectionView === breadcrumbCollectionView else { return layout.itemSize }
        let name = directoryName(for: breadcrumbURLs[indexPath.item])
        let width = (name as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14)]).width
        return CGSize(width: ceil(width) + 36, height: collectionView.bounds.height)
    }
}
