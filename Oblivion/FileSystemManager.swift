//
//  FileSystemManager.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import Foundation

enum FileOperationError: LocalizedError {
    case failMoveFile(String)
    case failCopyFile(String)
    case failCreateDirectory(String)
    case failDeleteFile(String)
    case invalidPath(URL)
    case fileAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case let .failMoveFile(message), let .failCopyFile(message),
             let .failCreateDirectory(message), let .failDeleteFile(message):
            return message
        case let .invalidPath(url):
            return "Cannot access or modify \(url.lastPathComponent): the path is unavailable or protected."
        case let .fileAlreadyExists(url):
            return "An item named \(url.lastPathComponent) already exists in this directory."
        }
    }
}

nonisolated enum DirectoryItem: Sendable {
    case file(URL)
    case directory(URL)

    var url: URL {
        switch self {
        case let .file(url), let .directory(url): return url
        }
    }
}

nonisolated enum FileTransferOperation: Sendable {
    case copy
    case move
}

extension FileManager {
    nonisolated func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}


nonisolated class FileSystemManager {
    private let fileManager = FileManager.default
    var documentsDirectory: URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    @concurrent
    static func readDirectory(at url: URL) async -> Result<[DirectoryItem], FileOperationError> {
        FileSystemManager().listDirectory(at: url)
    }

    func isImportInbox(at url: URL) -> Bool {
        guard url.isFileURL, let documentsDirectory else { return false }
        let inbox = documentsDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.pathComponents
        return url.standardizedFileURL.pathComponents.starts(with: inbox) ||
            url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: inbox)
    }

    func isProtectedPath(at url: URL) -> Bool {
        guard url.isFileURL, let documentsDirectory else { return true }
        let root = documentsDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        // Foundation leaves symlinks unresolved when the destination does not exist yet.
        while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        let target = resolved.standardizedFileURL.pathComponents
        return target.count <= root.count || !target.starts(with: root) ||
            isImportInbox(at: url) || isImportInbox(at: resolved)
    }
    
    // For deleting files
    public func deleteFile(path: URL, matching identifier: NSObject) -> Result<Void, FileOperationError> {
        guard !isProtectedPath(at: path) else { return .failure(.invalidPath(path)) }
        var path = path
        path.removeCachedResourceValue(forKey: .fileResourceIdentifierKey)
        do {
            guard let currentIdentifier = try path.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier as? NSObject, identifier.isEqual(currentIdentifier) else {
                return .failure(.failDeleteFile("The item changed after confirmation. Select it again."))
            }
            try fileManager.removeItem(at: path)
        } catch {
            return .failure(.failDeleteFile(error.localizedDescription))
        }
        return .success(())
    }
    
    // For listing directory
    public func listDirectory(at directory: URL) -> Result<[DirectoryItem], FileOperationError> {
        guard directory.isFileURL, let documentsDirectory,
              directory.resolvingSymlinksInPath().standardizedFileURL == documentsDirectory.resolvingSymlinksInPath().standardizedFileURL ||
                !isProtectedPath(at: directory) else {
            return .failure(.invalidPath(directory))
        }
        do {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            
            let items = contents.filter { !isImportInbox(at: $0) }.map { item in
                if fileManager.isDirectory(atPath: item.path) {
                    DirectoryItem.directory(item)
                }  else { DirectoryItem.file(item) }
            }
            
            return .success(items)
            
        } catch {
            return .failure(.invalidPath(directory))
        }
    }
    
    public func transferFile(path: URL, dst: URL, operation: FileTransferOperation) -> Result<Void, FileOperationError> {
        guard !isProtectedPath(at: dst) else { return .failure(.invalidPath(dst)) }
        guard operation != .move || !isProtectedPath(at: path) else {
            return .failure(.invalidPath(path))
        }
        guard !fileManager.fileExists(atPath: dst.path) else {
            return .failure(.fileAlreadyExists(dst))
        }
        do {
            switch operation {
            case .copy: try fileManager.copyItem(at: path, to: dst)
            case .move: try fileManager.moveItem(at: path, to: dst)
            }
            return .success(())
        } catch {
            return .failure(operation == .copy
                            ? .failCopyFile(error.localizedDescription)
                            : .failMoveFile(error.localizedDescription))
        }
    }
    
    public func createDir(named name: String, in parent: URL) -> Result<Void, FileOperationError> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            return .failure(.failCreateDirectory("Enter a valid directory name without slashes."))
        }
        let path = parent.appendingPathComponent(name, isDirectory: true)
        guard parent.isFileURL, fileManager.isDirectory(atPath: parent.path),
              !isProtectedPath(at: path) else {
            return .failure(.invalidPath(path))
        }
        guard !fileManager.fileExists(atPath: path.path) else {
            return .failure(.fileAlreadyExists(path))
        }
        do {
            try fileManager.createDirectory(
                at: path,
                withIntermediateDirectories: false,
                attributes: nil
            )
            return .success(())
        } catch {
            return .failure(.failCreateDirectory("\(error.localizedDescription)"))
        }
    }
}
