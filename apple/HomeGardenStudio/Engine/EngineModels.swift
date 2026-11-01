import Foundation

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    static func point(_ x: Double, _ y: Double) -> Self { .array([.number(x), .number(y)]) }
    static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }
    static func encode<T: Encodable>(_ value: T) throws -> Self { try JSONDecoder().decode(Self.self, from: EngineCodec.encoder().encode(value)) }
}

nonisolated struct EngineCommand: Encodable, Sendable {
    let fields: [String: JSONValue]
    init(_ op: String, _ fields: [String: JSONValue] = [:]) { self.fields = fields.merging(["op": .string(op)]) { _, new in new } }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
}
nonisolated struct EngineQuery: Encodable, Sendable {
    let fields: [String: JSONValue]
    init(_ q: String, _ fields: [String: JSONValue] = [:]) { self.fields = fields.merging(["q": .string(q)]) { _, new in new } }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
}
nonisolated struct Project: Codable, Sendable {
    var schema: Int; var name: String; var units: String; var nextSeq: Int
    var site: Site; var items: [Item]; var sources: [Source]; var backdrop: Backdrop?
}
nonisolated struct Site: Codable, Sendable {
    var boundary: [[Double]]?; var boundaryCertainty: String; var structures: [Structure]
}
nonisolated struct MeasurementEvidence: Codable, Sendable {
    var method: String; var values: [Double]; var note: String; var sourceId: String?
}
nonisolated struct Item: Codable, Identifiable, Sendable {
    var id: String; var kind: String; var name: String
    var x: Double; var y: Double; var width: Double; var depth: Double; var height: Double; var rotation: Double
    var params: [String: JSONValue]; var positionCertainty: String; var sizeCertainty: String
    var sourceIds: [String]; var product: ProductLink?; var locked: Bool; var notes: String
    var positionEvidence: MeasurementEvidence?; var sizeEvidence: MeasurementEvidence?
}
nonisolated struct ProductLink: Codable, Sendable { var title: String; var url: String; var listedDimensions: String }
nonisolated struct Structure: Codable, Identifiable, Sendable { var id: String; var name: String; var outline: [[Double]]; var height: Double; var certainty: String }
nonisolated struct Source: Codable, Identifiable, Sendable {
    var id: String; var kind: String; var title: String; var originalFilename: String?; var sha256: String?; var byteCount: Int
    var mediaType: String?; var url: String?; var pixelWidth: Int?; var pixelHeight: Int?; var registration: Registration?; var note: String
}
nonisolated struct Registration: Codable, Sendable { var p1: [Double]; var p2: [Double]; var distanceM: Double }
nonisolated struct Backdrop: Codable, Sendable { var sourceId: String; var x: Double; var y: Double; var rotation: Double; var opacity: Double; var metersPerPixel: Double? }
nonisolated struct CatalogEntry: Codable, Identifiable, Sendable {
    var id: String { kind }
    var kind: String; var label: String; var category: String; var shape: String
    var width: Double; var depth: Double; var height: Double; var sizeCertainty: String; var description: String; var product: ProductLink?
}
nonisolated struct Issue: Codable, Sendable { var itemId: String?; var code: String; var severity: String; var message: String }
nonisolated struct HistoryState: Codable, Sendable {
    var revision: Int?; var canUndo: Bool; var canRedo: Bool; var undoLabel: String?; var redoLabel: String?
    static let empty = Self(revision: 0, canUndo: false, canRedo: false, undoLabel: nil, redoLabel: nil)
}
nonisolated struct CommandResponse: Codable, Sendable { var ok: Bool; var revision: Int; var created: [String]; var changed: [String]; var removed: [String]; var history: HistoryState }
nonisolated struct IsoFace: Codable, Sendable { var itemId: String; var kind: String; var role: String; var points: [[Double]]; var depth: Double }
nonisolated struct Bounds: Codable, Sendable { var minX: Double; var minY: Double; var maxX: Double; var maxY: Double }
nonisolated struct IsoResult: Codable, Sendable { var faces: [IsoFace]; var bounds: Bounds }
nonisolated struct ScenePrimitive: Codable, Sendable { var itemId: String; var shape: String; var center: [Double]; var size: [Double]; var rotationY: Double; var material: String }
nonisolated struct SceneGround: Codable, Sendable { var min: [Double]; var max: [Double] }
nonisolated struct SceneResult: Codable, Sendable { var primitives: [ScenePrimitive]; var ground: SceneGround }
nonisolated struct RenderBrief: Codable, Sendable { var prompt: String; var items: [RenderBriefItem]; var uncertainties: [String]; var layoutHash: String }
nonisolated struct RenderBriefItem: Codable, Sendable { var id: String; var label: String; var dimensionsText: String; var positionCertainty: String; var sizeCertainty: String }
nonisolated struct Transform: Codable, Sendable {
    var x: Double; var y: Double; var width: Double; var depth: Double; var rotation: Double
    init(_ item: Item) { x = item.x; y = item.y; width = item.width; depth = item.depth; rotation = item.rotation }
    var fields: [String: JSONValue] { ["x": .number(x), "y": .number(y), "width": .number(width), "depth": .number(depth), "rotation": .number(rotation)] }
}
nonisolated struct TransformPreview: Codable, Sendable { var outline: [[Double]]; var issues: [Issue] }
nonisolated struct RotationResult: Codable, Sendable { var rotation: Double }
