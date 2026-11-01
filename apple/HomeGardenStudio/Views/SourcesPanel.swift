import SwiftUI
import ImageIO

struct SourcesPanel: View {
    @Bindable var store: PlanStore
    @Environment(\.undoManager) private var undoManager
    @State private var calibration: Source?
    var body: some View {
        List {
            Section {
                Text("Original files stay in this plan. Photos provide visual context. Two-point calibration sets scale only; it does not prove measured positions.").font(.callout)
            }
            if store.project.sources.isEmpty { ContentUnavailableView("No imported sources",systemImage:"photo.on.rectangle",description:Text("Import a photo, image, PDF, or page URL from the workspace toolbar.")) }
            ForEach(store.project.sources) { source in
                Section(source.title) {
                    LabeledContent("Type",value:source.mediaType ?? source.kind)
                    if let name = source.originalFilename { LabeledContent("Original",value:name) }
                    LabeledContent("Size",value:ByteCountFormatter.string(fromByteCount:Int64(source.byteCount),countStyle:.file))
                    if let sha = source.sha256 { LabeledContent("SHA-256",value:String(sha.prefix(16)) + "…").font(.caption.monospaced()) }
                    if let link = source.url, let url = URL(string:link), url.scheme == "https" { Link("Open source page",destination:url) }
                    Text(source.note).font(.caption).foregroundStyle(.secondary)
                    if source.sha256.flatMap({ store.document.original(sha: $0) }) == nil {
                        Label("Original unavailable: metadata only", systemImage: "exclamationmark.triangle").font(.caption)
                    }
                    if source.kind == "photo" {
                        Button("Use as backdrop") {
                            store.perform(EngineCommand("set_backdrop",["source_id":.string(source.id),"x":.number(0),"y":.number(0),"rotation":.number(0),"opacity":.number(0.6)]),undoManager:undoManager)
                        }
                        Button(source.registration == nil ? "Calibrate photo scale…" : "Recalibrate photo scale…") { calibration = source }
                        Text(source.registration == nil ? "Unregistered photo: not to scale." : "Scale calibrated; no position accuracy established.").font(.caption)
                    }
                    Button("Remove source reference",role:.destructive) { store.perform(EngineCommand("remove_source",["id":.string(source.id)]),undoManager:undoManager) }
                }
            }
            if store.project.backdrop != nil { Button("Clear backdrop") { store.perform(EngineCommand("set_backdrop",["clear":.bool(true)]),undoManager:undoManager) } }
        }.navigationTitle("Sources").sheet(item:$calibration) { source in CalibrationView(store:store,source:source) }
    }
}

private struct CalibrationView: View {
    var store:PlanStore
    let source:Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var image:CGImage?
    @State private var points:[CGPoint] = []
    @State private var distance = ""
    @State private var localError:String?
    @State private var coordinateText = ["", "", "", ""]
    var body:some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:12) {
                Text("Use a top-down image. Tap the ends of a known distance, then enter its measured length. Perspective and lens distortion remain uncorrected.").font(.callout)
                GeometryReader { geometry in
                    if let image {
                        let width = Double(source.pixelWidth ?? image.width), height = Double(source.pixelHeight ?? image.height)
                        let fit = min(geometry.size.width/width,geometry.size.height/height)
                        let size = CGSize(width:width*fit,height:height*fit)
                        let offset = CGPoint(x:(geometry.size.width-size.width)/2,y:(geometry.size.height-size.height)/2)
                        ZStack(alignment:.topLeading) {
                            Image(decorative:image,scale:1).resizable().frame(width:size.width,height:size.height).position(x:geometry.size.width/2,y:geometry.size.height/2)
                            ForEach(Array(points.enumerated()),id:\.offset) { index,p in
                                Text("\(index+1)").font(.caption.bold()).padding(6).background(.blue,in:Circle()).foregroundStyle(.white).position(x:p.x*fit+offset.x,y:p.y*fit+offset.y)
                            }
                        }.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { value in
                            let p = CGPoint(x:(value.location.x-offset.x)/fit,y:(value.location.y-offset.y)/fit)
                            guard p.x >= 0,p.y >= 0,p.x <= width,p.y <= height else { return }
                            if points.count == 2 { points = [] }; points.append(p)
                        })
                    } else { ProgressView("Loading original image").frame(maxWidth:.infinity,maxHeight:.infinity) }
                }.frame(minHeight:200)
                Text("Selected points: \(points.count) of 2").font(.caption)
                DisclosureGroup("Enter image pixel coordinates") {
                    HStack { TextField("Point 1 X", text: $coordinateText[0]); TextField("Point 1 Y", text: $coordinateText[1]) }
                    HStack { TextField("Point 2 X", text: $coordinateText[2]); TextField("Point 2 Y", text: $coordinateText[3]) }
                    Button("Use pixel coordinates") {
                        let values = coordinateText.compactMap(Double.init)
                        guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 }), let width = source.pixelWidth, let height = source.pixelHeight,
                            values[0] <= Double(width), values[2] <= Double(width), values[1] <= Double(height), values[3] <= Double(height) else {
                            localError = "Enter four pixel coordinates within this image."; return
                        }
                        points = [CGPoint(x: values[0], y: values[1]), CGPoint(x: values[2], y: values[3])]
                    }
                }

                TextField("Known distance, e.g. 4 m or 12 ft",text:$distance).textFieldStyle(.roundedBorder)
                Text("This changes backdrop scale only. Feature positions remain estimated.").font(.caption).foregroundStyle(.secondary)
                if let localError { Text(localError).foregroundStyle(.red).font(.caption) }
                Button("Apply scale calibration") {
                    guard points.count == 2, let meters = LengthFormatter.parse(distance,units:store.project.units) else { localError = "Select two points and enter their real distance."; return }
                    if store.perform(EngineCommand("register_source",["id":.string(source.id),"p1":.point(points[0].x,points[0].y),"p2":.point(points[1].x,points[1].y),"distance_m":.number(meters)]),undoManager:undoManager) { dismiss() } else { localError = store.error }
                }.buttonStyle(.borderedProminent).disabled(points.count != 2)
            }.padding().navigationTitle("Calibrate scale").toolbar { Button("Cancel") { dismiss() } }
        }.frame(minWidth:320,minHeight:500).task {
            guard let sha = source.sha256, let data = store.document.original(sha:sha) else { localError = "The original image is missing from this package."; return }
            image = await Task.detached(priority:.userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData,nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:2048] as CFDictionary)
            }.value
            if image == nil { localError = "This image could not be decoded." }
        }
    }
}
