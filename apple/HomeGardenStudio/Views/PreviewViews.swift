import SwiftUI
import RealityKit

struct IsometricView: View {
    var store: PlanStore
    @State private var angle = 0.0
    @State private var result: IsoResult?
    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                guard let result else { return }
                let b = result.bounds
                let scale = min((size.width-70)/max(1,b.maxX-b.minX),(size.height-70)/max(1,b.maxY-b.minY))
                let ox = (size.width-(b.maxX-b.minX)*scale)/2-b.minX*scale
                let oy = (size.height-(b.maxY-b.minY)*scale)/2-b.minY*scale
                for face in result.faces {
                    let path = Path { p in
                        guard let first = face.points.first else { return }
                        p.move(to: CGPoint(x:first[0]*scale+ox,y:first[1]*scale+oy))
                        for point in face.points.dropFirst() { p.addLine(to: CGPoint(x:point[0]*scale+ox,y:point[1]*scale+oy)) }
                        p.closeSubpath()
                    }
                    let opacity: Double = face.role == "top" ? 0.8 : face.role == "left" ? 0.6 : 0.45
                    context.fill(path, with: .color(Color.feature(face.kind).opacity(opacity)))
                    context.stroke(path, with: .color(.primary.opacity(0.3)), lineWidth:0.6)
                }
            }.background(Color.canvasBackground)
            .accessibilityLabel("Local isometric preview. Use Plan and the inspector to edit the layout.")
            HStack {
                Text("Local isometric preview").font(.caption)
                Spacer()
                Button("Rotate left",systemImage:"rotate.left") { angle = (angle + 270).truncatingRemainder(dividingBy: 360) }.labelStyle(.iconOnly)
                Slider(value:$angle,in:0...360,step:1).frame(maxWidth:180).accessibilityLabel("Isometric viewing angle")
                Button("Rotate right",systemImage:"rotate.right") { angle = (angle + 90).truncatingRemainder(dividingBy: 360) }.labelStyle(.iconOnly)
            }.padding()
        }.task(id: "\(store.revision)-\(angle)") {
            result = try? store.engine.query(EngineQuery("isometric",["view_angle":.number(angle)]),as:IsoResult.self).get()
        }
    }
}

struct Scene3DView: View {
    var store: PlanStore
    @State private var scene: SceneResult?
    @State private var sceneRevision = 0
    var body: some View {
        VStack(spacing:0) {
            if let scene {
                RealityView { content in
                    content.camera = .virtual
                    let root = makeScene(scene)
                    content.add(root)
                    content.cameraTarget = root
                }.realityViewCameraControls(.orbit)
                    .id(sceneRevision)
                    .accessibilityLabel("Local 3D layout preview. Drag to orbit. Use Plan and the inspector to edit.")
            } else { ProgressView("Building local 3D preview").frame(maxWidth:.infinity,maxHeight:.infinity) }
            Text("Local 3D preview: your layout with simplified models (not a photo)").font(.caption).padding().frame(maxWidth:.infinity)
        }.task(id:store.revision) {
            switch store.engine.query(EngineQuery("scene"),as:SceneResult.self) {
            case .success(let value): scene = value; sceneRevision = store.revision
            case .failure(let error): store.error = error.localizedDescription
            }
        }
    }
    private func makeScene(_ scene: SceneResult) -> Entity {
        let root = Entity()
        for primitive in scene.primitives {
            let mesh: MeshResource
            switch primitive.shape {
            case "sphere": mesh = .generateSphere(radius:0.5)
            case "cylinder": mesh = .generateCylinder(height:1,radius:0.5)
            default: mesh = .generateBox(size:1)
            }
            #if os(macOS)
            let color = NSColor(Color.feature(primitive.material))
            #else
            let color = UIColor(Color.feature(primitive.material))
            #endif
            let model = ModelEntity(mesh:mesh,materials:[SimpleMaterial(color:color,roughness:0.8,isMetallic:primitive.material == "metal")])
            model.name = primitive.itemId
            model.position = SIMD3<Float>(Float(primitive.center[0]),Float(primitive.center[1]),Float(primitive.center[2]))
            model.scale = SIMD3<Float>(Float(max(0.01,primitive.size[0])),Float(max(0.01,primitive.size[1])),Float(max(0.01,primitive.size[2])))
            model.orientation = simd_quatf(angle:Float(primitive.rotationY * .pi / 180),axis:[0,1,0])
            root.addChild(model)
        }
        let width = Float(max(1,scene.ground.max[0]-scene.ground.min[0])), depth = Float(max(1,scene.ground.max[1]-scene.ground.min[1]))
        let ground = ModelEntity(mesh:.generateBox(width:width,height:0.02,depth:depth),materials:[SimpleMaterial(color:.init(red:0.55,green:0.64,blue:0.48,alpha:1),roughness:1,isMetallic:false)])
        ground.position = [Float((scene.ground.min[0]+scene.ground.max[0])/2),-0.03,Float((scene.ground.min[1]+scene.ground.max[1])/2)]
        root.addChild(ground)
        let light = DirectionalLight(); light.light.intensity = 2500
        light.look(at:[0,0,0],from:[8,20,10],relativeTo:nil); root.addChild(light)
        return root
    }
}
