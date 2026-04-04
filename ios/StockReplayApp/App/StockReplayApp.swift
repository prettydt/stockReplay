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
        TabView {
            StockListView()
                .tabItem {
                    Label("行情", systemImage: "chart.xyaxis.line")
                }

            NavigationStack {
                SubscriptionView()
            }
            .tabItem {
                Label("会员", systemImage: "person.crop.circle.badge.checkmark")
            }
        }
        .tint(settings.selectedTheme.accentColor)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 1180, minHeight: 760)
        #endif
    }
}
