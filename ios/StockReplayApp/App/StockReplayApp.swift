import SwiftUI

@main
struct StockReplayApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(settings)
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}

struct RootTabView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        StockListView()
            .tint(settings.selectedTheme.accentColor)
            .preferredColorScheme(.dark)
            #if os(macOS)
            .frame(minWidth: 1180, minHeight: 760)
            #endif
    }
}
