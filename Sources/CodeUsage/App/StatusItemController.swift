import AppKit
import Combine
import SwiftUI

/// Owns the menu bar status item: renders `MenuBarLabel` into a template image, toggles the popover
/// on left click and shows a small menu on right click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let contextMenu: NSMenu
    private var cancellables = Set<AnyCancellable>()
    private var lastImageData: Data?
    /// When the popover last closed; a click that closed the transient popover must not reopen it.
    private var popoverClosedAt: Date = .distantPast

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.contextMenu = NSMenu()
        super.init()

        configureButton()
        configurePopover()
        configureMenu()
        observe()
        updateImage()
    }

    // MARK: Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.behavior = []
        statusItem.autosaveName = "CodeUsageStatusItem"
    }

    private func configurePopover() {
        let hosting = NSHostingController(rootView: PopoverView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func configureMenu() {
        let refresh = NSMenuItem(title: "새로고침", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        contextMenu.items = [refresh, settings, .separator(), quit]
        contextMenu.delegate = self
    }

    private func observe() {
        // Store changes: objectWillChange fires before the new value is set, so debounce on main and read afterwards.
        store.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateImage() }
            }
            .store(in: &cancellables)

        // Menu bar toggles live in UserDefaults.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateImage() }
            }
            .store(in: &cancellables)

        // Backing scale can change when displays are attached/detached.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateImage(force: true) }
            }
            .store(in: &cancellables)

        // Sessions expire and reset times pass without a store change: re-render periodically.
        Timer.publish(every: 30, tolerance: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateImage() }
            }
            .store(in: &cancellables)
    }

    // MARK: Rendering

    /// Highest backing scale of any attached screen (at least 2), so the bitmap stays sharp on a Retina
    /// menu bar even when the status item was first laid out on a 1x display. AppKit downsamples for 1x.
    private var backingScale: CGFloat {
        max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
    }

    func updateImage(force: Bool = false) {
        guard let button = statusItem.button else { return }
        let now = Date()
        let scale = backingScale

        let renderer = ImageRenderer(content: MenuBarLabel(store: store, forTemplate: true, now: now))
        renderer.scale = scale
        renderer.isOpaque = false
        guard let cgImage = renderer.cgImage else { return }

        let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        let image = NSImage(size: size)
        image.addRepresentation({
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = size
            return rep
        }())
        image.isTemplate = true

        let description = MenuBarLabel.accessibilityText(store: store, now: now)
        button.toolTip = description
        button.setAccessibilityLabel(description)

        // Skip redundant updates (the 30 s timer usually renders an identical image).
        let fingerprint = Self.fingerprint(cgImage)
        if !force, fingerprint == lastImageData, button.image != nil { return }
        lastImageData = fingerprint

        button.image = image
        statusItem.length = NSStatusItem.variableLength
        button.invalidateIntrinsicContentSize()
        button.needsLayout = true
        button.needsDisplay = true
    }

    private static func fingerprint(_ image: CGImage) -> Data? {
        guard let data = image.dataProvider?.data else { return nil }
        var result = data as Data
        withUnsafeBytes(of: (image.width, image.height)) { result.append(contentsOf: $0) }
        return result
    }

    // MARK: Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else if Date().timeIntervalSince(popoverClosedAt) > 0.25 {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        store.refreshIfStale(maxAge: 30)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func showMenu() {
        closePopover()
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
    }

    @objc private func refreshNow() {
        Task { await store.refresh() }
    }

    @objc private func openSettings() {
        WindowManager.shared.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        popoverClosedAt = Date()
    }

    // MARK: NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left click goes to the popover again.
        statusItem.menu = nil
    }
}
