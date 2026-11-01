import SwiftUI

struct LibraryPanel: View {
    var store:PlanStore
    @Environment(\.undoManager) private var undoManager
    var body:some View {
        List {
            Section { Text("Drag a feature onto the plan, or select Add to place it at the canvas centre.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(Set(store.catalog.map(\.category))).sorted(),id:\.self) { category in
                Section(category.capitalized) {
                    ForEach(store.catalog.filter { $0.category == category }) { entry in
                        VStack(alignment:.leading,spacing:6) {
                            HStack {
                                Label(entry.label,systemImage:symbol(entry.kind)).font(.headline)
                                Spacer()
                                Button { store.add(entry.kind,undoManager:undoManager) } label: { Label("Add \(entry.label)",systemImage:"plus.circle") }.labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityIdentifier("library.add." + entry.kind)
                            }
                            Text("\(LengthFormatter.format(entry.width,units:store.project.units)) × \(LengthFormatter.format(entry.depth,units:store.project.units)) × \(LengthFormatter.format(entry.height,units:store.project.units))").font(.caption)
                            Text(entry.description).font(.caption).foregroundStyle(.secondary)
                            if let product = entry.product, let url = URL(string:product.url), url.scheme == "https" { Link("Product listing",destination:url).font(.caption); Text(product.listedDimensions).font(.caption2) }
                        }.padding(.vertical,4).draggable(LibraryPayload(kind:entry.kind))
                    }
                }
            }
        }.navigationTitle("Feature library")
    }
    private func symbol(_ kind:String)->String {
        switch kind { case "plant","tree":"leaf"; case "pond":"water.waves"; case "fire_pit":"flame"; case "bin_screen","fence","privacy_screen":"rectangle.split.3x1"; default:"square.on.square" }
    }
}
