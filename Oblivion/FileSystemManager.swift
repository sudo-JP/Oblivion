//
//  FileSystemManager.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import Foundation

enum FileOperationError: Error {
    case failMoveFile(String)
    case failCopyFile(String)
    case failCreateDirectory(String)
    case failDeleteFile(String)
    case invalidPath(URL)
    case fileAlreadyExists(URL)
}

enum DirectoryItem {
    case file(URL)
    case directory(URL)
}

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}


class FileSystemManager {
    private let fileManager = FileManager.default
    var documentsDirectory: URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    
    // For deleting files
    public func deleteFile(path: URL) -> Result<Void, FileOperationError> {
        do {
            try fileManager.removeItem(at: path)
        } catch {
            return .failure(.failDeleteFile("\(error)"))
        }
        return .success(())
    }
    
    // For listing directory
    public func listDirectory(at directory: URL) -> Result<[DirectoryItem], FileOperationError> {
        do {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            
            let items = contents.map { item in
                if item.hasDirectoryPath {
                    DirectoryItem.directory(item)
                }  else { DirectoryItem.file(item) }
            }
            
            return .success(items)
            
        } catch {
            return .failure(.invalidPath(directory))
        }
    }
    
    // Moving file
    public func moveFile(path: URL, dst: URL) -> Result<Void, FileOperationError> {
        do {
            try fileManager.moveItem(at: path, to: dst)
            return .success(())
        } catch {
            return .failure(.failMoveFile("\(error)"))
        }
    }

    public func copyFile(path: URL, dst: URL) -> Result<Void, FileOperationError> {
        guard !fileManager.fileExists(atPath: dst.path) else {
            return .failure(.fileAlreadyExists(dst))
        }
        do {
            try fileManager.copyItem(at: path, to: dst)
            return .success(())
        } catch {
            return .failure(.failCopyFile(error.localizedDescription))
        }
    }
    
    public func createDir(at path: URL) -> Result<Void, FileOperationError> {
        do {
            try fileManager.createDirectory(
                at: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return .success(())
        } catch {
            return .failure(.failCreateDirectory("\(error.localizedDescription)"))
        }
    }
}
