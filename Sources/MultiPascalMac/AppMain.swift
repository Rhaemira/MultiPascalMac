// Created by Amirali Yazdani on 10/16/26.
import Foundation
import MPWinCore

#if canImport(SwiftUI)
import AppKit
import SwiftUI

/// Forces the app to behave like a normal, frontmost, keyboard-focused macOS
/// application. This matters because this target is a Swift Package
/// executable: when it's launched straight from Xcode's default scheme for a
/// SwiftPM product (rather than as a proper double-clicked .app bundle), macOS
/// sometimes does not treat the process as a standard foreground GUI app.
/// The window can appear without ever becoming key, which makes text views
/// such as the source editor look "frozen" — clicking into them does nothing
/// because the window never actually has keyboard focus.
final class MultiPascalMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MultiPascalMacApp: App {
    @NSApplicationDelegateAdaptor(MultiPascalMacAppDelegate.self) private var appDelegate
    @StateObject private var model = MPWinAppModel()

    var body: some Scene {
        WindowGroup("Multi-Pascal Mac") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 720)
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "mpf" else { return }
                    model.loadSource(url: url)
                }
        }
        .commands {
            MultiPascalCommands(model: model)
        }
    }
}
#else

@main
struct MultiPascalMacFallback {
    static func main() {
        print("Multi-Pascal Mac is a macOS SwiftUI application. Build this target on macOS.")
    }
}
#endif
