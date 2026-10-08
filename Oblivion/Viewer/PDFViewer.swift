//
//  PDFViewer.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import Foundation
import PDFKit
import UIKit

class PDFViewer: Viewable {
    var pageCount: Int
    let document: PDFDocument
    
    init?(url: URL) {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            return nil
        }
        self.document = document
        self.pageCount = document.pageCount
    }
    
    func image(forPage index: Int, size: CGSize) -> Result<UIImage, RetrieveViewableError> {
        guard index >= 0, index < pageCount,
              let page = document.page(at: index) else {
            return .failure(.IndexOutOfRange)
        }
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return .failure(.InvalidSize)
        }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.minX.isFinite, pageRect.minY.isFinite,
              pageRect.width.isFinite, pageRect.height.isFinite,
              pageRect.width > 0, pageRect.height > 0 else {
            return .failure(.InvalidPageBounds)
        }
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let fittedSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: fittedSize)
        let img = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: fittedSize))
            
            ctx.cgContext.translateBy(x: 0, y: fittedSize.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.translateBy(x: -pageRect.minX, y: -pageRect.minY)
            
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        
        return .success(img)
    }
    
}
