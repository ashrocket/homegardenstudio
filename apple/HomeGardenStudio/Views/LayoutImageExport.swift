import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

nonisolated private struct LayoutImageSnapshot: Sendable {
    let project: Project
    let outlines: [String: [[Double]]]
    let backdrop: Data?
}
nonisolated enum LayoutImageExport {
    @MainActor static func png(store: PlanStore, includeBackdrop: Bool) async throws -> Data {
        var outlines: [String: [[Double]]] = [:]
        for item in store.project.items { outlines[item.id] = try store.engine.query(EngineQuery("outline", ["id": .string(item.id)]), as: [[Double]].self).get() }
        let source = store.project.sources.first { $0.id == store.project.backdrop?.sourceId }
        let backdrop = includeBackdrop ? source?.sha256.flatMap { store.document.original(sha: $0) } : nil
        let snapshot = LayoutImageSnapshot(project: store.project, outlines: outlines, backdrop: backdrop)
        return try await Task.detached(priority: .userInitiated) { try draw(snapshot) }.value
    }
    /// A derived reference for an explicitly approved upload; the package original stays untouched.
    @concurrent static func referenceJPEG(_ original: Data) async throws -> Data {
        guard original.count <= ImportService.maxFileBytes, let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary),
              let data = CFDataCreateMutable(nil, 0), let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw LocalAIError.invalidResponse }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), CFDataGetLength(data) <= 4 * 1024 * 1024 else { throw LocalAIError.responseTooLarge }
        return data as Data
    }
    private static func draw(_ snapshot: LayoutImageSnapshot) throws -> Data {
        let pixels = 1024
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LocalAIError.failed }
        context.setFillColor(CGColor(gray: 0.98, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        context.translateBy(x: 0, y: CGFloat(pixels)); context.scaleBy(x: 1, y: -1)
        let points = (snapshot.project.site.boundary ?? []) + snapshot.project.site.structures.flatMap(\.outline) + snapshot.outlines.values.flatMap { $0 }
        let minX = points.map { $0[0] }.min() ?? 0, minY = points.map { $0[1] }.min() ?? 0
        let maxX = points.map { $0[0] }.max() ?? 24, maxY = points.map { $0[1] }.max() ?? 18
        let scale = min(900 / max(1, maxX - minX), 840 / max(1, maxY - minY))
        let originX = (1024 - (maxX - minX) * scale) / 2 - minX * scale
        let originY = 85 + (840 - (maxY - minY) * scale) / 2 - minY * scale
        func point(_ p: [Double]) -> CGPoint { CGPoint(x: p[0] * scale + originX, y: p[1] * scale + originY) }
        func polygon(_ points: [[Double]]) -> CGPath {
            let path = CGMutablePath(); guard let first = points.first else { return path }
            path.move(to: point(first)); points.dropFirst().forEach { path.addLine(to: point($0)) }; path.closeSubpath(); return path
        }
        func text(_ value: String, at position: CGPoint, size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let string = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)])
            context.saveGState(); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1); context.textPosition = position
            CTLineDraw(CTLineCreateWithAttributedString(string), context); context.restoreGState()
        }
        if let bytes = snapshot.backdrop, let backdrop = snapshot.project.backdrop,
           let source = snapshot.project.sources.first(where: { $0.id == backdrop.sourceId }),
           let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary) {
            let mpp = backdrop.metersPerPixel ?? 20 / Double(source.pixelWidth ?? image.width)
            let width = Double(source.pixelWidth ?? image.width) * mpp * scale, height = Double(source.pixelHeight ?? image.height) * mpp * scale
            let p = point([backdrop.x, backdrop.y])
            context.saveGState(); context.setAlpha(backdrop.opacity); context.translateBy(x: p.x, y: p.y); context.rotate(by: backdrop.rotation * .pi / 180)
            context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1); context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); context.restoreGState()
        }
        if let boundary = snapshot.project.site.boundary {
            context.addPath(polygon(boundary)); context.setStrokeColor(CGColor(gray: 0.2, alpha: 1)); context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: snapshot.project.site.boundaryCertainty == "estimated" ? [7, 5] : []); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
        }
        for structure in snapshot.project.site.structures { context.addPath(polygon(structure.outline)); context.setFillColor(CGColor(gray: 0.7, alpha: 1)); context.fillPath() }
        for item in snapshot.project.items {
            guard let outline = snapshot.outlines[item.id] else { continue }
            let color: CGColor
            switch item.kind {
            case "plant", "tree": color = CGColor(srgbRed: 0.25, green: 0.55, blue: 0.28, alpha: 0.9)
            case "pond": color = CGColor(srgbRed: 0.25, green: 0.65, blue: 0.8, alpha: 0.9)
            case "fire_pit": color = CGColor(srgbRed: 0.72, green: 0.5, blue: 0.28, alpha: 0.9)
            default: color = CGColor(srgbRed: 0.58, green: 0.5, blue: 0.4, alpha: 0.9)
            }
            context.addPath(polygon(outline)); context.setFillColor(color); context.fillPath()
            context.addPath(polygon(outline)); context.setStrokeColor(CGColor(gray: 0.15, alpha: 0.7)); context.setLineWidth(1); context.strokePath()
            let p = point([item.x, item.y + item.depth / 2 + 0.2])
            text(String(item.name.prefix(40)), at: CGPoint(x: p.x - 25, y: p.y), size: 12)
        }
        text(String(snapshot.project.name.prefix(70)), at: CGPoint(x: 38, y: 38), size: 24)
        text("Layout proposal • retained dimensions and source uncertainty • not a survey", at: CGPoint(x: 38, y: 988), size: 15)
        guard let image = context.makeImage(), let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw LocalAIError.failed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), CFDataGetLength(data) <= 4 * 1024 * 1024 else { throw LocalAIError.responseTooLarge }
        return data as Data
    }
}
