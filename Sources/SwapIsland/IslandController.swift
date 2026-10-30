import AppKit
import Combine
import IslandCore
import SwiftUI

/// A panel that can be clicked without taking focus from the app being worked in.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel is never frontmost, so without this the first click only focuses it and the button misses.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the window, the menu bar item and the open/close rules. The window spans the largest open
/// size at all times and takes the mouse only while the cursor is over the island itself, so
/// everything under its transparent area keeps its clicks.
@MainActor
final class IslandController: NSObject {
    private static let windowMargin: CGFloat = 40
    private static let hoverDelay: Duration = .milliseconds(90)
    private static let closeDelay: Duration = .milliseconds(180)
    /// Stays under the shoulder drop, so the cursor reaching a menu bar icon counts as leaving.
    private static let closeSlack: CGFloat = 8

    private let store: IslandStore
    private let updater: IslandUpdater
    private let space = IslandSpace()
    private var panel: IslandPanel?
    private var statusItem: NSStatusItem?
    private var geometry: NotchGeometry?
    private var monitors: [Any] = []
    private var pendingTransition: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var lastRowCount = -1
    private var desiredOpen: Bool?
    /// Opened from the menu bar item, with the cursor elsewhere: leaving cannot close what was never entered.
    private var isPinned = false
    private var ownsCursor = false

    init(store: IslandStore, updater: IslandUpdater) {
        self.store = store
        self.updater = updater
    }

    func start() {
        allowCursorChangesInBackground()
        rebuildWindow()
        installMonitors()
        installStatusItem()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuildWindow() } }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateFullscreen()
                    // Again once the swipe has settled, or a stale answer would last until the next swipe.
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        self?.updateFullscreen()
                    }
                }
            }
            .store(in: &cancellables)

        store.$accounts
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in
                // The new value lands after this publisher fires, so read it on the next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuildWindowIfRowsChanged() } }
            }
            .store(in: &cancellables)
    }

    func stop() {
        space.destroy()
    }

    func openPinned() {
        isPinned = true
        transition(toOpen: true)
    }

    private var bodySize: CGSize {
        IslandMetrics.bodySize(accountCount: store.accounts.count, isAdding: store.showsExtraSection)
    }

    private func rebuildWindowIfRowsChanged() {
        guard store.accounts.count != lastRowCount else { return }
        rebuildWindow()
    }

    private func rebuildWindow() {
        guard let screen = Self.targetScreen() else { return }
        let geometry = NotchGeometry(
            screen: screen.frame,
            topInset: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRight: screen.auxiliaryTopRightArea?.width
        )
        self.geometry = geometry
        lastRowCount = store.accounts.count

        let largest = IslandMetrics.bodySize(accountCount: store.accounts.count, isAdding: true)
        let frame = geometry.windowFrame(bodySize: largest, margin: Self.windowMargin)
        let existingPanel = self.panel
        let panel = existingPanel ?? Self.makePanel()
        panel.setFrame(frame, display: true)
        panel.contentView = FirstClickHostingView(rootView: IslandView(store: store, updater: updater, geometry: geometry))
        updateMouseCapture(for: panel, geometry: geometry)
        panel.orderFrontRegardless()
        if existingPanel == nil { space.host(panel) }
        self.panel = panel
        updateFullscreen()
    }

    private func updateFullscreen() {
        guard let screen = Self.targetScreen() else { return }
        store.isFullscreen = isShowingFullscreenSpace(on: screen)
    }

    /// The built-in display when it has a notch, otherwise wherever the menu bar lives.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func makePanel() -> IslandPanel {
        let panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = Bundle.main.image(forResource: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: nil)
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            image?.accessibilityDescription = "Swap Island"
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.toolTip = "Swap Island"
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if store.isOpen {
            transition(toOpen: false)
        } else {
            openPinned()
        }
    }

    // MARK: - Hover

    /// Global monitors see the mouse over other apps; the local one sees it over this panel,
    /// which global monitors skip. Mouse monitors need no Accessibility permission.
    private func installMonitors() {
        // Scrolling moves the rows under a still cursor, so it counts as a move too.
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        let pressed: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        addGlobal(moved) { $0.handleMouseMoved() }
        addLocal(moved) { $0.handleMouseMoved() }
        addGlobal(pressed) { $0.handleGlobalPress() }
    }

    private func addGlobal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (IslandController) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }) {
            monitors.append(monitor)
        }
    }

    private func addLocal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (IslandController) -> Void) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func updateMouseCapture(for panel: NSPanel, geometry: NotchGeometry) {
        let isOver = geometry.isOverOpenShape(at: NSEvent.mouseLocation, bodySize: bodySize)
        panel.ignoresMouseEvents = !(store.isOpen && isOver)
    }

    private func handleMouseMoved() {
        guard let geometry, let panel else { return }
        updateMouseCapture(for: panel, geometry: geometry)
        let point = NSEvent.mouseLocation
        updateHover(at: point, panel: panel, geometry: geometry)
        if store.isOpen {
            if geometry.isOverIsland(at: point, bodySize: bodySize) { isPinned = false }
            guard !isPinned else { return }
            let stays = geometry.isOverIsland(at: point, bodySize: bodySize, slack: Self.closeSlack)
            setDesired(open: stays, after: Self.closeDelay)
        } else {
            setDesired(open: geometry.triggersOpen(at: point, wingsHidden: store.isFullscreen), after: Self.hoverDelay)
        }
    }

    /// The cursor is set on every move over the panel, because the frontmost app can set its own between moves.
    private func updateHover(at point: CGPoint, panel: NSPanel, geometry: NotchGeometry) {
        var account: Int?
        if store.isOpen, geometry.isOverOpenShape(at: point, bodySize: bodySize) {
            let inWindow = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
            (HoverAreas.isOverButton(inWindow) ? NSCursor.pointingHand : NSCursor.arrow).set()
            ownsCursor = true
            account = store.needsOnboarding ? nil : HoverAreas.account(at: inWindow)
        } else if ownsCursor {
            NSCursor.arrow.set()
            ownsCursor = false
        }
        if store.hoveredAccount != account { store.hoveredAccount = account }
    }

    private func handleGlobalPress() {
        guard let geometry else { return }
        let point = NSEvent.mouseLocation
        // The item's own action decides this click. Handling it here too races with that action,
        // so the panel would open and close at once, or close and reopen.
        guard !isOverStatusItem(point) else { return }
        if store.isOpen {
            if !geometry.isOverOpenShape(at: point, bodySize: bodySize) { transition(toOpen: false) }
        } else if geometry.triggersOpen(at: point, wingsHidden: store.isFullscreen) {
            transition(toOpen: true)
        }
    }

    /// Wider than the button because the menu bar pads each item.
    private func isOverStatusItem(_ point: CGPoint) -> Bool {
        guard let frame = statusItem?.button?.window?.frame else { return false }
        return frame.insetBy(dx: -8, dy: 0).contains(point)
    }

    /// Debounced, so sweeping the cursor across the menu bar does not flash the panel.
    private func setDesired(open: Bool, after delay: Duration) {
        guard open != store.isOpen else {
            pendingTransition?.cancel()
            desiredOpen = nil
            return
        }
        guard desiredOpen != open else { return }
        desiredOpen = open
        pendingTransition?.cancel()
        pendingTransition = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.transition(toOpen: open)
        }
    }

    private func transition(toOpen open: Bool) {
        pendingTransition?.cancel()
        desiredOpen = nil
        guard open != store.isOpen else { return }
        store.isOpen = open
        if !open {
            isPinned = false
            store.isAdding = false
            store.hoveredAccount = nil
        }
        if let panel, let geometry { updateMouseCapture(for: panel, geometry: geometry) }
        if open { Task { await store.refresh() } }
    }
}
