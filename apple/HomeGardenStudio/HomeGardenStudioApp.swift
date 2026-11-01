import SwiftUI

@main struct HomeGardenStudioApp: App {
    @State private var services = StudioServices()
    var body:some Scene {
        DocumentGroup(newDocument: { PlanDocument() }) { configuration in
            DocumentWorkspace(document:configuration.document,fileURL:configuration.fileURL, services:services)
        }
        #if os(macOS)
        .defaultSize(width:1100,height:760)
        #endif
    }
}
