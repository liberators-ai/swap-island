import AppKit

/// Takes the island out of the Space-switch animation.
///
/// A `.stationary` window still gets composited into a three-finger swipe, so it dims and ghosts
/// along with the desktop while the notch itself obviously stays put. A private space at the top
/// absolute level sits outside that transition. This is private API: fine for an app we ship
/// ourselves, and the reason it could never go through the App Store.
@MainActor
final class IslandSpace {
    private static let topLevel = Int(Int32.max)
    /// Must be 1. Other values make Finder draw desktop icons into the space.
    private static let plainSpaceFlag = 1

    private let connection = _CGSDefaultConnection()
    private let identifier: UInt64

    init() {
        identifier = CGSSpaceCreate(connection, Self.plainSpaceFlag, nil)
        CGSSpaceSetAbsoluteLevel(connection, identifier, Self.topLevel)
        CGSShowSpaces(connection, [identifier] as NSArray)
    }

    /// The window needs a window number, so call this after it has been ordered in.
    func host(_ window: NSWindow) {
        CGSAddWindowsToSpaces(connection, [window.windowNumber] as NSArray, [identifier] as NSArray)
    }

    func destroy() {
        CGSHideSpaces(connection, [identifier] as NSArray)
        CGSSpaceDestroy(connection, identifier)
    }
}

/// macOS ignores `NSCursor.set()` from an app that is not frontmost, and the island never is,
/// because activating it would take focus from the app being worked in. Same private API family.
func allowCursorChangesInBackground() {
    let connection = _CGSDefaultConnection()
    _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

/// There is no public way to ask this about another app's window.
func isShowingFullscreenSpace(on screen: NSScreen) -> Bool {
    let fullscreenSpaceType = 4
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
    let identifier = uuid.map { CFUUIDCreateString(nil, $0) as String }
    let displays = CGSCopyManagedDisplaySpaces(_CGSDefaultConnection())?.takeRetainedValue() as? [[String: Any]]
    // "Main" stands for all displays while "Displays have separate Spaces" is off.
    let display = displays?.first {
        let name = $0["Display Identifier"] as? String
        return name == identifier || name == "Main"
    }
    let current = display?["Current Space"] as? [String: Any]
    return current?["type"] as? Int == fullscreenSpaceType
}

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ owner: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32
@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ connection: Int32, _ flag: Int, _ options: NSDictionary?) -> UInt64
@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ connection: Int32, _ space: UInt64)
@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ connection: Int32, _ space: UInt64, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ connection: Int32, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ connection: Int32, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ connection: Int32, _ spaces: NSArray)
