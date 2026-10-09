import AppKit
import SwiftUI

@main
struct ClaudeSeatSwitcherApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(DemoWindow.self) private var demoWindow

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                if !model.menuBarTitle.isEmpty {
                    Text(model.menuBarTitle)
                }
            }
            .foregroundStyle(model.highestPercent >= AppModel.warnPercent ? .red : .primary)
        }
        .menuBarExtraStyle(.window)

        Window("Add account", id: "add-account") {
            AddAccountView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

/// In `--demo` mode, also shows the menu panel in a plain window so it can be screenshotted.
final class DemoWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppModel.isDemo else { return }
        let model = AppModel()
        let view = MenuView().environmentObject(model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: view.background(.regularMaterial))
        w.setContentSize(w.contentView!.fittingSize)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 12
        w.contentView?.layer?.masksToBounds = true
        let screen = NSScreen.main!.frame
        w.setFrameTopLeftPoint(NSPoint(x: 100, y: screen.maxY - 100))
        w.level = .floating
        w.orderFrontRegardless()
        window = w
        print("DEMO_WINDOW \(Int(w.frame.minX)) \(Int(screen.maxY - w.frame.maxY)) \(Int(w.frame.width)) \(Int(w.frame.height))")
        fflush(stdout)
    }
}
