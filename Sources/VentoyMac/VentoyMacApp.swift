import SwiftUI

@main
struct VentoyMacApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("VentoyMac") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.assetManager)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("设备") {
                Button("重新扫描外接磁盘") {
                    state.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
