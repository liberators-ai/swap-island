import AppKit
import IslandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: IslandStore?
    private var controller: IslandController?
    private var updater: IslandUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let store = IslandStore(
            client: CswapClient.locate(),
            hidesEmails: environment["SWAP_ISLAND_HIDE_EMAILS"] != nil
        )
        let updater = IslandUpdater(demoVersion: environment["SWAP_ISLAND_DEMO_UPDATE"])
        let controller = IslandController(store: store, updater: updater)
        self.store = store
        self.controller = controller
        self.updater = updater
        controller.start()
        store.start()
        updater.start(isIdle: { !store.isOpen && !store.isBusy })
        // The first launch shows the import step. The variable lets a screenshot catch the open
        // state without moving the mouse.
        if store.needsOnboarding || environment["SWAP_ISLAND_START_OPEN"] != nil {
            controller.openPinned()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
