import AppKit
import SwiftUI

/// Opens single instances of the Settings and History windows and brings them to front.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    /// Called right before a window is shown (the status item uses it to close its popover).
    var onWillShowWindow: (() -> Void)?

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    private override init() {
        super.init()
    }

    func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: "Code Usage 설정",
            rootView: SettingsView(),
            resizable: false,
            autosaveName: "CodeUsage.SettingsWindow"
        )
        settingsWindow = window
        present(window)
    }

    func showHistory(store: UsageStore) {
        let window = historyWindow ?? makeWindow(
            title: "사용량 기록",
            rootView: HistoryView(store: store),
            resizable: true,
            autosaveName: "CodeUsage.HistoryWindow"
        )
        historyWindow = window
        present(window)
    }

    private func makeWindow<Content: View>(title: String, rootView: Content, resizable: Bool, autosaveName: String) -> NSWindow {
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = resizable ? [.minSize] : [.preferredContentSize, .minSize, .maxSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window.styleMask = style
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.layoutIfNeeded()
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    private func present(_ window: NSWindow) {
        onWillShowWindow?()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
