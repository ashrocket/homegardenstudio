import SwiftUI
import ImageIO

struct RenderImagePreview: View {
    let bytes: Data
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        Group { if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else if failed { ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark") } else { ProgressView("Loading image") } }
            .task(id: bytes) {
                image = nil; failed = false
                let result = await Task.detached(priority: .userInitiated) {
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary)
                }.value
                guard !Task.isCancelled else { return }
                image = result; failed = result == nil
            }
    }
}
