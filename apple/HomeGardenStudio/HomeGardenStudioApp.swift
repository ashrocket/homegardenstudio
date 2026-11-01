import SwiftUI

@main struct HomeGardenStudioApp: App {
    var body:some Scene {
        DocumentGroup(newDocument: { PlanDocument() }) { configuration in
            DocumentWorkspace(document:configuration.document,fileURL:configuration.fileURL)
        }
        #if os(macOS)
        .defaultSize(width:1100,height:760)
        #endif
    }
}
