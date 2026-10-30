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

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32
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
