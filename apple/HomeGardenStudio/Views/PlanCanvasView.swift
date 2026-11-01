import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO

nonisolated struct LibraryPayload: Codable, Transferable, Sendable {
    let kind: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .gardenFeature) }
}
extension UTType { nonisolated static let gardenFeature = UTType(exportedAs: "com.ashleyraiteri.homegardenstudio.feature") }

struct PlanCanvasView: View {
    @Bindable var store: PlanStore
    @Environment(\.undoManager) private var undoManager
    @State private var scale: Double = 28
    @State private var origin = CGPoint(x: 40, y: 40)
    @State private var pan = CGSize.zero
    @State private var canvasSize = CGSize.zero
    @State private var zoomStart: Double?
    @State private var suppressDragForZoom = false
    @State private var outlines: [String: [[Double]]] = [:]
    @State private var preview: TransformPreview?
    @State private var proposed: Transform?
    @State private var dragItem: Item?
    @State private var dragMode: DragMode?
    @State private var backdropImage: CGImage?
    @GestureState private var dragging = false
    private enum DragMode { case pan, move, resize(Double, Double), rotate, boundary }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in draw(&context, size: size) }
                .background(Color.canvasBackground)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if zoomStart == nil { zoomStart = scale; suppressDragForZoom = true; clearDrag() }
                    scale = min(200, max(5, (zoomStart ?? scale) * value.magnification))
                }.onEnded { _ in zoomStart = nil; if !dragging { suppressDragForZoom = false }; updateCenter(geometry.size) })
                .dropDestination(for: LibraryPayload.self) { payloads, location in
                    guard let payload = payloads.first, store.catalog.contains(where: { $0.kind == payload.kind }) else { return false }
                    store.add(payload.kind, at: world(location), undoManager: undoManager); return true
                }
                .focusable()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { key in
                    guard !store.selection.isEmpty else { return .ignored }
                    let distance = key.modifiers.contains(.shift) ? 1.0 : 0.1
                    let dx = key.key == .leftArrow ? -distance : key.key == .rightArrow ? distance : 0
                    let dy = key.key == .upArrow ? -distance : key.key == .downArrow ? distance : 0
                    store.perform(EngineCommand("move_items", ["ids": .strings(Array(store.selection)), "dx": .number(dx), "dy": .number(dy)]), undoManager: undoManager)
                    return .handled
                }
                .onKeyPress(.delete) { store.remove(undoManager: undoManager); return .handled }
                .accessibilityLabel("Garden plan canvas").accessibilityIdentifier("preview.plan")
                .accessibilityHint("Use the feature list and inspector to select, position, resize, and rotate features without dragging.")
                .overlay(alignment: .bottomLeading) { canvasStatus }
                .overlay(alignment: .bottomTrailing) {
                    HStack {
                        Button("Zoom out", systemImage: "minus.magnifyingglass") { scale = max(5, scale / 1.25); updateCenter(geometry.size) }
                        Button("Fit plan", systemImage: "arrow.up.left.and.arrow.down.right") { fit(geometry.size) }
                        Button("Zoom in", systemImage: "plus.magnifyingglass") { scale = min(200, scale * 1.25); updateCenter(geometry.size) }
                    }.labelStyle(.iconOnly).buttonStyle(.bordered).padding()
                }
                #if os(macOS)
                .background(ScrollWheelZoom { delta in scale = min(200, max(5, scale * exp(-delta * 0.01))); updateCenter(geometry.size) })
                #endif
                .task(id: store.revision) { refreshOutlines() }
                .task(id: store.project.backdrop?.sourceId) { await loadBackdrop() }
                .onChange(of: store.fitRequest) { _, _ in fit(geometry.size) }
                .onChange(of: geometry.size) { _, size in updateCenter(size) }
                .onChange(of: dragging) { _, value in if !value { clearDrag(); if zoomStart == nil { suppressDragForZoom = false } } }
                .onAppear { fit(geometry.size) }
        }
    }
    private var canvasStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.drawingBoundary { Text("Tap boundary corners, then choose Done. Boundary is estimated.").font(.callout) }
            if let backdrop = store.project.backdrop {
                Text(backdrop.metersPerPixel == nil ? "Unregistered photo: not to scale." : "Photo scale calibrated. Positions remain estimated.").font(.caption).bold()
            }
            if let preview, !preview.issues.isEmpty { Label(preview.issues[0].message, systemImage: "exclamationmark.triangle").font(.caption) }
            Text(store.project.units == "metric" ? "Grid: 1 metre" : "Grid: 1 foot").font(.caption).foregroundStyle(.secondary)
        }.padding(10).background(.background, in: RoundedRectangle(cornerRadius: 8)).padding().allowsHitTesting(false)
    }
    private func screen(_ point: [Double]) -> CGPoint { CGPoint(x: point[0] * scale + origin.x + pan.width, y: point[1] * scale + origin.y + pan.height) }
    private func world(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale) }
    private func path(_ points: [[Double]]) -> Path {
        Path { p in guard let first = points.first else { return }; p.move(to: screen(first)); for point in points.dropFirst() { p.addLine(to: screen(point)) }; p.closeSubpath() }
    }
    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let spacing = (store.project.units == "metric" ? 1.0 : 0.3048) * scale
        if spacing >= 7 {
            var grid = Path()
            let ox = (origin.x + pan.width).truncatingRemainder(dividingBy: spacing)
            let oy = (origin.y + pan.height).truncatingRemainder(dividingBy: spacing)
            for x in stride(from: ox, through: size.width, by: spacing) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: oy, through: size.height, by: spacing) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
        }
        if let image = backdropImage, let backdrop = store.project.backdrop, let source = store.project.sources.first(where: { $0.id == backdrop.sourceId }) {
            let mpp = backdrop.metersPerPixel ?? (20.0 / Double(source.pixelWidth ?? image.width))
            var photo = context; photo.opacity = backdrop.opacity
            let center = screen([backdrop.x, backdrop.y]); photo.translateBy(x: center.x, y: center.y); photo.rotate(by: .degrees(backdrop.rotation))
            let width = Double(source.pixelWidth ?? image.width) * mpp * scale, height = Double(source.pixelHeight ?? image.height) * mpp * scale
            photo.draw(Image(decorative: image, scale: 1), in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let boundary = store.project.site.boundary {
            let boundaryPath = path(boundary)
            context.fill(boundaryPath, with: .color(.green.opacity(0.035)))
            context.stroke(boundaryPath, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: store.project.site.boundaryCertainty == "estimated" ? [7,5] : []))
        }
        for structure in store.project.site.structures {
            context.fill(path(structure.outline), with: .color(.gray.opacity(0.35)))
            context.stroke(path(structure.outline), with: .color(.secondary), lineWidth: 1.5)
            if let p = structure.outline.first { context.draw(Text(structure.name).font(.caption), at: screen(p), anchor: .topLeading) }
        }
        for item in store.project.items {
            guard let outline = outlines[item.id] else { continue }
            let p = path(outline)
            context.fill(p, with: .color(Color.feature(item.kind).opacity(0.65)))
            context.stroke(p, with: .color(Color.feature(item.kind)), lineWidth: store.selection.contains(item.id) ? 3 : 1)
            drawSymbol(item, context: &context)
            let labelPoint = screen([item.x, item.y + item.depth / 2 + 0.35])
            context.draw(Text(item.name).font(.caption).foregroundStyle(.primary), at: labelPoint)
            if store.selection.contains(item.id) {
                context.draw(Text("\(LengthFormatter.format(item.width, units: store.project.units)) × \(LengthFormatter.format(item.depth, units: store.project.units))").font(.caption2), at: CGPoint(x: labelPoint.x, y: labelPoint.y + 14))
                for corner in corners(item) { context.fill(Path(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)), with: .color(.accentColor)) }
                let rotate = rotationPoint(item); var stem = Path(); stem.move(to: screen([item.x,item.y])); stem.addLine(to: rotate)
                context.stroke(stem, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [3,3]))
                context.fill(Path(ellipseIn: CGRect(x: rotate.x - 6, y: rotate.y - 6, width: 12, height: 12)), with: .color(.accentColor))
            }
            if store.issues.contains(where: { $0.itemId == item.id }) {
                context.draw(Image(systemName: "exclamationmark.triangle.fill"), at: screen([item.x + item.width / 2, item.y - item.depth / 2]))
            }
        }
        if let preview { context.stroke(path(preview.outline), with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, dash: [5,3])) }
        if !store.boundaryPoints.isEmpty { context.stroke(path(store.boundaryPoints), with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [4,4])) }
    }
    private func drawSymbol(_ item: Item, context: inout GraphicsContext) {
        var c = context; let p = screen([item.x,item.y]); c.translateBy(x: p.x,y: p.y); c.rotate(by: .degrees(item.rotation))
        let w = item.width * scale, d = item.depth * scale
        if item.kind == "plant" || item.kind == "tree" {
            for angle in stride(from: 0.0, to: 360.0, by: 60) {
                let a = angle * .pi / 180; let r = w * 0.2
                c.stroke(Path(ellipseIn: CGRect(x: cos(a)*r-w*0.18,y: sin(a)*r-d*0.18,width: w*0.36,height: d*0.36)), with: .color(.white.opacity(0.6)), lineWidth: 1)
            }
        } else if item.kind == "fire_pit" {
            let diameter: Double = { if case .number(let value) = item.params["pit_diameter"] { return value }; return 1.07 }()
            let clearance: Double = { if case .number(let value) = item.params["clearance"] { return value }; return 3.05 }()
            let radius = (diameter / 2 + clearance) * scale
            c.stroke(Path(ellipseIn: CGRect(x:-radius,y:-radius,width:radius*2,height:radius*2)), with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [6,4]))
            c.fill(Path(ellipseIn: CGRect(x:-diameter*scale/2,y:-diameter*scale/2,width:diameter*scale,height:diameter*scale)), with: .color(.orange))
        } else if item.kind == "pergola" || item.kind == "sauna" {
            var slats = Path()
            for x in stride(from: -w/2 + 4, through: w/2 - 4, by: max(5,w/9)) { slats.move(to: CGPoint(x:x,y:-d/2)); slats.addLine(to: CGPoint(x:x,y:d/2)) }
            c.stroke(slats, with: .color(.primary.opacity(0.35)), lineWidth: 1)
        } else if item.kind == "pond" {
            c.stroke(Path(ellipseIn: CGRect(x:-w*0.35,y:-d*0.35,width:w*0.7,height:d*0.7)), with: .color(.white.opacity(0.65)), lineWidth: 1)
        }
    }
    private func corners(_ item: Item) -> [CGPoint] { [(-1.0,-1.0),(1.0,-1.0),(1.0,1.0),(-1.0,1.0)].map { sx,sy in
        let a = item.rotation * .pi / 180, x = sx * item.width / 2, y = sy * item.depth / 2
        return screen([item.x + x*cos(a)-y*sin(a), item.y+x*sin(a)+y*cos(a)])
    } }
    private func rotationPoint(_ item: Item) -> CGPoint { let a = item.rotation * .pi / 180, r = item.depth/2+0.8; return screen([item.x+r*sin(a),item.y-r*cos(a)]) }
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0).updating($dragging) { _, state, _ in state = true }.onChanged { value in
            guard !suppressDragForZoom else { return }
            if dragMode == nil { beginDrag(value.startLocation) }
            guard let mode = dragMode else { return }
            if case .pan = mode { pan = value.translation; return }
            guard let item = dragItem else { return }
            var transform = Transform(item); let point = world(value.location)
            switch mode {
            case .move: transform.x += value.translation.width / scale; transform.y += value.translation.height / scale
            case .resize(let sx, let sy):
                if case .success(let result) = store.engine.query(EngineQuery("resize_handle", ["id": .string(item.id), "handle": .point(sx,sy), "point": .point(point.x,point.y), "proportional": .bool(snap)]), as: Transform.self) { transform = result }
            case .rotate:
                let start = world(value.startLocation)
                if case .success(let result) = store.engine.query(EngineQuery("rotate_handle", ["id": .string(item.id), "start": .point(start.x,start.y), "point": .point(point.x,point.y), "snap": .bool(snap)]), as: RotationResult.self) { transform.rotation = result.rotation }
            default: return
            }
            proposed = transform
            preview = try? store.engine.query(EngineQuery("preview_transform", transform.fields.merging(["id": .string(item.id)]) { _,v in v }), as: TransformPreview.self).get()
        }.onEnded { value in
            if suppressDragForZoom { suppressDragForZoom = false; clearDrag(); return }
            if case .boundary = dragMode { let p = world(value.location); store.boundaryPoints.append([p.x,p.y]) }
            else if case .pan = dragMode { origin.x += value.translation.width; origin.y += value.translation.height }
            else if let item = dragItem, let proposed, hypot(value.translation.width,value.translation.height) > 2 {
                store.perform(EngineCommand("set_transform", proposed.fields.merging(["id": .string(item.id)]) { _,v in v }), undoManager: undoManager)
            }
            clearDrag(); updateCenter(canvasSize)
        }
    }
    private var snap: Bool {
        #if os(macOS)
        store.snapTransforms || NSEvent.modifierFlags.contains(.shift)
        #else
        store.snapTransforms
        #endif
    }
    private func beginDrag(_ location: CGPoint) {
        if store.drawingBoundary { dragMode = .boundary; return }
        if let item = store.selectedItem(), !item.locked {
            if hypot(rotationPoint(item).x-location.x,rotationPoint(item).y-location.y) < 16 { dragItem = item; dragMode = .rotate; return }
            let signs = [(-1.0,-1.0),(1.0,-1.0),(1.0,1.0),(-1.0,1.0)]
            for (index,p) in corners(item).enumerated() where hypot(p.x-location.x,p.y-location.y) < 16 { dragItem = item; dragMode = .resize(signs[index].0,signs[index].1); return }
        }
        let point = world(location)
        let hit = try? store.engine.query(EngineQuery("hit_test", ["point": .point(point.x,point.y), "tolerance": .number(6/scale)]), as: String?.self).get()
        if let id = hit, let item = store.project.items.first(where: { $0.id == id }) { store.selection = [id]; dragItem = item; dragMode = item.locked ? nil : .move }
        else { store.selection = []; dragMode = .pan }
    }
    private func clearDrag() { pan = .zero; preview = nil; proposed = nil; dragItem = nil; dragMode = nil }
    private func refreshOutlines() { outlines = Dictionary(uniqueKeysWithValues: store.project.items.compactMap { item in
        guard let points = try? store.engine.query(EngineQuery("outline", ["id": .string(item.id)]), as: [[Double]].self).get() else { return nil }; return (item.id, points)
    }) }
    private func updateCenter(_ size: CGSize) { canvasSize = size; store.canvasCenter = world(CGPoint(x:size.width/2,y:size.height/2)) }
    private func fit(_ size: CGSize) {
        let points = (store.project.site.boundary ?? []) + store.project.site.structures.flatMap(\.outline) + store.project.items.flatMap { item in [[item.x-item.width,item.y-item.depth],[item.x+item.width,item.y+item.depth]] }
        let minX = points.map { $0[0] }.min() ?? 0, minY = points.map { $0[1] }.min() ?? 0
        let maxX = points.map { $0[0] }.max() ?? 24, maxY = points.map { $0[1] }.max() ?? 18
        scale = max(5,min(80,min((size.width-100)/max(1,maxX-minX),(size.height-130)/max(1,maxY-minY))))
        origin = CGPoint(x:(size.width-(maxX-minX)*scale)/2-minX*scale,y:(size.height-(maxY-minY)*scale)/2-minY*scale-20); updateCenter(size)
    }
    private func loadBackdrop() async {
        guard let id = store.project.backdrop?.sourceId, let sha = store.project.sources.first(where: { $0.id == id })?.sha256, let data = store.document.original(sha: sha) else { backdropImage = nil; return }
        backdropImage = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData,nil) else { return nil as CGImage? }
            return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:2048] as CFDictionary)
        }.value
    }
}

extension Color {
    static var canvasBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static func feature(_ kind: String) -> Color {
        switch kind { case "plant", "tree", "foliage": .green; case "pond", "water": .cyan; case "fire_pit", "fire": .orange; case "patio", "path", "stone", "gravel": .gray; case "metal": .secondary; default: .brown }
    }
}

#if os(macOS)
import AppKit
private struct ScrollWheelZoom: NSViewRepresentable {
    let zoom: (Double) -> Void
    func makeNSView(context: Context) -> WheelView { let view = WheelView(); view.zoom = zoom; return view }
    func updateNSView(_ view: WheelView, context: Context) { view.zoom = zoom }
    final class WheelView: NSView {
        var zoom: ((Double) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.window === event.window, self.bounds.contains(self.convert(event.locationInWindow, from:nil)) else { return event }
                self.zoom?(event.scrollingDeltaY); return nil
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
