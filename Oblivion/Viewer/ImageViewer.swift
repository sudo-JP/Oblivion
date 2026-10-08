import UIKit

class ImageViewer: Viewable {
    let pageCount = 1
    let sourceImage: UIImage

    init?(url: URL) {
        guard let image = UIImage(contentsOfFile: url.path),
              image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        sourceImage = image
    }

    func image(forPage index: Int, size: CGSize) -> Result<UIImage, RetrieveViewableError> {
        guard index == 0 else {
            return .failure(.IndexOutOfRange)
        }
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return .failure(.InvalidSize)
        }
        let scale = min(size.width / sourceImage.size.width, size.height / sourceImage.size.height)
        let imageSize = CGSize(
            width: sourceImage.size.width * scale,
            height: sourceImage.size.height * scale
        )
        let imageRect = CGRect(origin: .zero, size: imageSize)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(imageRect)
            sourceImage.draw(in: imageRect)
        }
        return .success(image)
    }
}
