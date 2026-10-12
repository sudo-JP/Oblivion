import UIKit

final class ImageViewer: NSObject, Viewable, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView: UIImageView
    var onPageChange: ((Int) -> Void)?
    var contentView: UIView { scrollView }
    let pageCount = 1
    let currentPage = 0
    var isZoomed: Bool { scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 }

    private init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init()
        imageView.contentMode = .scaleAspectFit
        scrollView.backgroundColor = .black
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.addSubview(imageView)
    }

    static func open(_ url: URL) async -> Result<any Viewable, ViewerError> {
        let image = await decodeImage(at: url)
        guard !Task.isCancelled else { return .failure(.rendering(.Cancelled)) }
        guard let image else { return .failure(.cannotOpen(url)) }
        return .success(ImageViewer(image: image))
    }

    @concurrent private static func decodeImage(at url: URL) async -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path),
              image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image.preparingForDisplay() ?? image
    }

    func fitToView() {
        scrollView.zoomScale = 1
        imageView.frame = scrollView.bounds
        scrollView.contentSize = scrollView.bounds.size
    }

    func toggleZoom(at point: CGPoint) {
        guard !isZoomed else {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let center = scrollView.convert(point, to: imageView)
        let size = CGSize(width: scrollView.bounds.width / 2, height: scrollView.bounds.height / 2)
        scrollView.zoom(to: CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width, height: size.height
        ), animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}
