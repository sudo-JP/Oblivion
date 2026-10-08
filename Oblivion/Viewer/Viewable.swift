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
}

protocol Viewable {
    var pageCount: Int { get }
    //func thumbnail(size: CGSize) throws -> UIImage
    func image(forPage index: Int, size: CGSize) -> Result<UIImage, RetrieveViewableError>
}
