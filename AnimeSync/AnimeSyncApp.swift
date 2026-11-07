import SwiftUI

@main struct AnimeSyncApp: App {
    @StateObject private var bootstrap = AppBootstrap()
    var body: some Scene {
        WindowGroup {
            Group {
                if let model = bootstrap.model { AppRoot(model: model) }
                else { VStack(spacing: 20) { Image("anime-sync-logo").resizable().frame(width: 88,height: 88); if let error = bootstrap.error { Text(error).multilineTextAlignment(.center); Button("Try again") { Task { await bootstrap.start() } } } else { ProgressView("Opening Anime Sync…") } }.padding(30).frame(maxWidth: .infinity,maxHeight: .infinity).background(Theme.background) }
            }.preferredColorScheme(.dark).tint(Theme.accent).task { await bootstrap.start() }
        }
    }
}
