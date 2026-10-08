//
//  Viewable.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import UIKit

enum RetrieveViewableError: Error {
    case InvalidSize
    case Cancelled
}

protocol Viewable: AnyObject {
    var contentView: UIView { get }
    var pageCount: Int { get }
    var currentPage: Int { get }
    var isZoomed: Bool { get }
    var onPageChange: ((Int) -> Void)? { get set }
    func toggleZoom(at point: CGPoint)
    func fitToView()
}
