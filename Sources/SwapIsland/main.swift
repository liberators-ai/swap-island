import AppKit
import IslandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: IslandStore?
    private var controller: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let store = IslandStore(
            client: CswapClient.locate(),
            hidesEmails: environment["SWAP_ISLAND_HIDE_EMAILS"] != nil
        )
        let controller = IslandController(store: store)
        self.store = store
        self.controller = controller
        controller.start()
        store.start()
        // Lets a screenshot catch the open state without moving the mouse.
        if environment["SWAP_ISLAND_START_OPEN"] != nil {
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
