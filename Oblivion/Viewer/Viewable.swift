//
//  Viewable.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import UIKit

enum RetrieveViewableError: Error {
    case IndexOutOfRange
    case InvalidSize
    case InvalidPageBounds
    case CannotOpen
    case Cancelled
}

nonisolated protocol Viewable: Sendable {
    func open() async -> Result<Int, ViewerError>
    func image(forPage index: Int, size: CGSize) async -> Result<UIImage, RetrieveViewableError>
}
