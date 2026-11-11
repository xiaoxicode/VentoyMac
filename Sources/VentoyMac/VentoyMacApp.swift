import AppKit
import SwiftUI

@main
struct VentoyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("VentoyMac", id: MainWindow.id) {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.assetManager)
                .background(MainWindow.Registrar())
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") { MainWindow.show() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("设备") {
                Button("重新扫描外接磁盘") {
                    state.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

/// Single-window plumbing.
///
/// SwiftUI's `WindowGroup` keeps the process alive after the last window is
/// closed, but it does **not** rebuild that window when the user clicks the
/// Dock icon: AppKit sends `applicationShouldHandleReopen`, and with no window
/// in the scene graph the event is simply dropped. The app then sits in the
/// Dock as a dead icon — exactly what happens right after an install, when the
/// user closes the window and later clicks the Dock.
///
/// Two things are needed to fix it: recreate the window (`openWindow`, only
/// reachable from a view environment, hence the captured closure) and
/// de-miniaturise / re-front an existing one (`WindowGroup` has no equivalent,
/// so it needs AppKit).
enum MainWindow {
    static let id = "main"

    /// Captured once from a live view. `OpenWindowAction` stays valid after the
    /// originating window is destroyed, so this survives closing the window.
    @MainActor private static var opener: (() -> Void)?

    struct Registrar: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    MainWindow.opener = { openWindow(id: MainWindow.id) }
                }
        }
    }

    /// Brings the main window back, whatever state it is in: closed, minimised,
    /// or simply behind another app.
    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        let windows = NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }
        guard !windows.isEmpty else {
            opener?()
            // The scene rebuild is not synchronous; activating again once the
            // window exists avoids leaving it behind the previous app.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            return
        }
        for window in windows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A manually bundled SwiftPM executable can launch as a background app
        // when started from a non-GUI context; force a normal Dock presence.
        NSApp.setActivationPolicy(.regular)
    }

    /// Keep the process alive when the window closes so logs and settings
    /// survive; `MainWindow.show()` is what brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
