//
//  ImportHandler.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//
import Foundation

class ImportHandler {
    private let fileSystemManager = FileSystemManager()
    
    public func handle(url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else { return false }
        
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to get security-scoped access to the file.")
            return false
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        // TODO
    }
}
