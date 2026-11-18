import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore.shared
        let controller = StatusItemController(store: store)
        statusController = controller
        WindowManager.shared.onWillShowWindow = { [weak controller] in
            controller?.closePopover()
        }
        store.start()
    }

    /// Launching the app again (Finder, Spotlight, `open`) shows the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { statusController?.showPopover() }
        return false
    }

    /// Make sure the last queued history write reaches disk before the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        UsageStore.shared.flushHistory()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
