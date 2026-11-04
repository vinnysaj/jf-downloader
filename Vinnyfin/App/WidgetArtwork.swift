#if os(iOS) || os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The small pictures widgets show: scaled down with ImageIO, which never decodes the picture at
/// full size, and kept as JPEGs.
nonisolated enum WidgetArtwork {
    /// A JPEG of the picture no bigger than `maxPixelSize` on its longest side. Nil when the
    /// picture can't be read, which leaves the widget's placeholder in its place.
    static func jpeg(from source: CGImageSource, maxPixelSize: Int, quality: Double) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
