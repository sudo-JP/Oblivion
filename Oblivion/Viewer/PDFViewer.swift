//
//  PDFViewer.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import Foundation
import PDFKit

class PDFViewer: Viewable {
    var pageCount: Int
    let document: PDFDocument
    
    init?(url: URL) {
        guard let document = PDFDocument(url: url) else {
            return nil
        }
        self.document = document
        self.pageCount = document.pageCount
    }
    
    func image(forPage index: Int, size: CGSize) -> Result<UIImage, RetrieveViewableError> {
        guard let page = document.page(at: index) else {
            return .failure(.IndexOutOfRange)
        }
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return .failure(.InvalidSize)
        }
        let pageRect = page.bounds(for: .mediaBox)
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let offsetX = (size.width - pageRect.width * scale) / 2
        let offsetY = (size.height - pageRect.height * scale) / 2
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: size))
            
            ctx.cgContext.translateBy(x: offsetX, y: size.height - offsetY)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.translateBy(x: -pageRect.minX, y: -pageRect.minY)
            
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        
        return .success(img)
    }
    
}
