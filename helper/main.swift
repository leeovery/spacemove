// spacemove: list macOS Spaces (named from Spaceman) and move the focused window to one.
//
//   spacemove list [--json]
//   spacemove move <number | name | id:ID> [--follow] [--json] [--method auto|direct|compat|drag]
//   spacemove doctor
//
// Moving tries these routes, in order, and checks the WindowServer after each:
//   bridged  macOS 26.4+: an SLSBridgedMoveWindowsToManagedSpaceOperation handed to SkyLight's
//            window-management bridge (WMClientWindowManager), which does the move for us. This is
//            what exported SLSMoveWindowsToManagedSpace does internally, but only when
//            SLSWindowManagementClientOperationsEnabled() says so; sending it directly skips that check.
//   direct   SLSMoveWindowsToManagedSpace. Blocked by Apple for other apps' windows from 14.5.
//   compat   yabai's 14.5 workaround: tag the target space with a compat ID, move the window to it.
//   drag     only with --method drag: hold the title bar and press "Switch to Desktop N".

import ApplicationServices
import Cocoa

// MARK: - Private symbols, resolved at run time so a missing one degrades instead of crashing

private let libraryPaths: [String] = [
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
]
private let libraries: [UnsafeMutableRawPointer] =
    libraryPaths.compactMap { dlopen($0, RTLD_LAZY) } + [UnsafeMutableRawPointer(bitPattern: -2)!]  // RTLD_DEFAULT

private func resolve<T>(_ names: [String], as _: T.Type) -> T? {
    for name in names {
        for lib in libraries {
            if let pointer = dlsym(lib, name) { return unsafeBitCast(pointer, to: T.self) }
        }
    }
    return nil
}

private typealias ConnectionFn = @convention(c) () -> Int32
private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> UnsafeRawPointer?
private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
private typealias MoveWindowsFn = @convention(c) (Int32, CFArray, UInt64) -> Void
private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> UnsafeRawPointer?
private typealias SetCompatIDFn = @convention(c) (Int32, UInt64, Int32) -> Int32
private typealias SetWorkspaceFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32
private typealias HotKeyValueFn = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
private typealias HotKeyEnabledFn = @convention(c) (Int32) -> Bool
private typealias SetHotKeyEnabledFn = @convention(c) (Int32, Bool) -> Int32
private typealias AXWindowIDFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

private enum SLS {
    static let mainConnection = resolve(["SLSMainConnectionID", "CGSMainConnectionID"], as: ConnectionFn.self)
    static let copyDisplaySpaces = resolve(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyDisplaySpacesFn.self)
    static let activeSpace = resolve(["SLSGetActiveSpace", "CGSGetActiveSpace"], as: ActiveSpaceFn.self)
    static let moveWindows = resolve(["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"], as: MoveWindowsFn.self)
    static let copySpacesForWindows = resolve(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindowsFn.self)
    static let setCompatID = resolve(["SLSSpaceSetCompatID", "CGSSpaceSetCompatID"], as: SetCompatIDFn.self)
    static let setWorkspace = resolve(["SLSSetWindowListWorkspace", "CGSSetWindowListWorkspace"], as: SetWorkspaceFn.self)
    static let hotKeyValue = resolve(["CGSGetSymbolicHotKeyValue", "SLSGetSymbolicHotKeyValue"], as: HotKeyValueFn.self)
    static let hotKeyEnabled = resolve(["CGSIsSymbolicHotKeyEnabled", "SLSIsSymbolicHotKeyEnabled"], as: HotKeyEnabledFn.self)
    static let setHotKeyEnabled = resolve(["CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled"], as: SetHotKeyEnabledFn.self)
    static let axWindowID = resolve(["_AXUIElementGetWindow"], as: AXWindowIDFn.self)

    static let cid: Int32 = mainConnection?() ?? 0

    static let all: [(String, Bool)] = [
        ("MainConnectionID", mainConnection != nil),
        ("CopyManagedDisplaySpaces", copyDisplaySpaces != nil),
        ("GetActiveSpace", activeSpace != nil),
        ("MoveWindowsToManagedSpace", moveWindows != nil),
        ("CopySpacesForWindows", copySpacesForWindows != nil),
        ("SpaceSetCompatID", setCompatID != nil),
        ("SetWindowListWorkspace", setWorkspace != nil),
        ("GetSymbolicHotKeyValue", hotKeyValue != nil),
        ("IsSymbolicHotKeyEnabled", hotKeyEnabled != nil),
        ("SetSymbolicHotKeyEnabled", setHotKeyEnabled != nil),
        ("_AXUIElementGetWindow", axWindowID != nil),
    ]
}

// MARK: - Spaces

struct Space: Codable {
    let id: UInt64
    let number: Int?  // Mission Control's "Desktop N"; nil for a full-screen space
    let name: String?  // Spaceman's label, if any
    let display: String
    let displayIndex: Int
    let fullscreen: Bool
    let current: Bool  // the visible space on its display
    let active: Bool  // the visible space on the display with focus

    var title: String {
        if fullscreen { return name ?? "Full screen" }
        return "\(number ?? 0): \(name ?? "Desktop \(number ?? 0)")"
    }
}

func activeSpaceID() -> UInt64 { SLS.activeSpace?(SLS.cid) ?? 0 }

func spacemanNames() -> [UInt64: String] {
    guard let data = UserDefaults(suiteName: "dev.ruittenb.Spaceman")?.data(forKey: "spaceNames"),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return [:] }
    var names: [UInt64: String] = [:]
    for (key, value) in plist {
        if let id = UInt64(key), let entry = value as? [String: Any],
           let name = entry["spaceName"] as? String, !name.isEmpty {
            names[id] = name
        }
    }
    return names
}

func loadSpaces() -> [Space] {
    guard let copy = SLS.copyDisplaySpaces, let raw = copy(SLS.cid) else { return [] }
    let displays = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as? [[String: Any]] ?? []
    let names = spacemanNames()
    let active = activeSpaceID()
    var spaces: [Space] = []
    var desktop = 0
    for (index, display) in displays.enumerated() {
        let identifier = display["Display Identifier"] as? String ?? "?"
        let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        for space in display["Spaces"] as? [[String: Any]] ?? [] {
            guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
            let fullscreen = (space["type"] as? NSNumber)?.intValue == 4
            var number: Int?
            if !fullscreen { desktop += 1; number = desktop }
            spaces.append(Space(
                id: id, number: number, name: names[id], display: identifier, displayIndex: index + 1,
                fullscreen: fullscreen, current: id == current, active: id == active))
        }
    }
    return spaces
}

func spaces(of window: CGWindowID) -> [UInt64] {
    guard let copy = SLS.copySpacesForWindows,
          let raw = copy(SLS.cid, 0x7, [NSNumber(value: window)] as CFArray)
    else { return [] }
    return (Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as? [NSNumber] ?? []).map(\.uint64Value)
}

func resolveTarget(_ query: String, in spaces: [Space]) throws -> Space {
    if query.hasPrefix("id:"), let id = UInt64(query.dropFirst(3)) {
        if let match = spaces.first(where: { $0.id == id }) { return match }
        throw Failure("No Space with id \(id)")
    }
    if let number = Int(query) {
        if let match = spaces.first(where: { $0.number == number }) { return match }
        throw Failure("No Desktop \(number); there are \(spaces.compactMap(\.number).count)")
    }
    let q = query.lowercased()
    let named = spaces.filter { $0.name != nil }
    for test in [{ (n: String) in n == q }, { $0.hasPrefix(q) }, { $0.contains(q) }] {
        let matches = named.filter { test($0.name!.lowercased()) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw Failure("\"\(query)\" matches \(matches.map(\.title).joined(separator: ", "))")
        }
    }
    throw Failure("No Space named \"\(query)\"")
}

// MARK: - Windows

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
}

func onScreenWindows() -> [WindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { info in
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return WindowInfo(id: id, pid: pid, layer: layer, bounds: bounds)
    }
}

func windowOwner(_ id: CGWindowID) -> pid_t? {
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first else { return nil }
    return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
}

func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

func windowID(of element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard SLS.axWindowID?(element, &id) == .success, id != 0 else { return nil }
    return id
}

struct FocusedWindow {
    let pid: pid_t
    let id: CGWindowID
    let element: AXUIElement?
    var appName: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)" }
}

func isRaycast(_ pid: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.hasPrefix("com.raycast") ?? false
}

func currentFocusedWindow() -> FocusedWindow? {
    if AXIsProcessTrusted() {
        let system = AXUIElementCreateSystemWide()
        if let app: AXUIElement = axValue(system, kAXFocusedApplicationAttribute),
           let window: AXUIElement = axValue(app, kAXFocusedWindowAttribute),
           let id = windowID(of: window) {
            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            return FocusedWindow(pid: pid, id: id, element: window)
        }
    }
    // Without Accessibility: the frontmost app's topmost normal window.
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    guard let top = onScreenWindows().first(where: { $0.pid == pid && $0.layer == 0 }) else { return nil }
    return FocusedWindow(pid: pid, id: top.id, element: nil)
}

/// Raycast hands focus back to the previous app as it closes; give that a moment.
func focusedWindow() -> FocusedWindow? {
    let deadline = Date().addingTimeInterval(1.0)
    repeat {
        if let window = currentFocusedWindow(), !isRaycast(window.pid) { return window }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    } while Date() < deadline
    return nil
}

func focus(_ element: AXUIElement, pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
}

/// After sending a window away, give focus to the next window on this display, as closing one would.
func focusNextWindow(after moved: CGWindowID, near frame: CGRect?) {
    guard AXIsProcessTrusted() else { return }
    let candidates = onScreenWindows().filter { info in
        info.layer == 0 && info.id != moved && info.bounds.width > 40 && info.bounds.height > 40
            && NSRunningApplication(processIdentifier: info.pid)?.activationPolicy == .regular
    }
    let sameDisplay = frame.flatMap { f in candidates.first(where: { displayID(containing: $0.bounds) == displayID(containing: f) }) }
    guard let next = sameDisplay ?? candidates.first else { return }
    let app = AXUIElementCreateApplication(next.pid)
    let windows: [AXUIElement] = axValue(app, kAXWindowsAttribute) ?? []
    if let element = windows.first(where: { windowID(of: $0) == next.id }) {
        focus(element, pid: next.pid)
    } else {
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}

// MARK: - Displays

func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 16, &ids, &count)
    return count > 0 ? ids[0] : nil
}

func displayID(forIdentifier identifier: String) -> CGDirectDisplayID? {
    if identifier == "Main" { return CGMainDisplayID() }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    for id in ids.prefix(Int(count)) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
        if (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(identifier) == .orderedSame { return id }
    }
    return nil
}

/// A space on another display: put the window on that display first, or it lands off-screen.
func placeOnDisplay(_ window: FocusedWindow, frame: CGRect?, target: Space) {
    guard let element = window.element, let frame,
          let targetDisplay = displayID(forIdentifier: target.display),
          displayID(containing: frame) != targetDisplay
    else { return }
    let bounds = CGDisplayBounds(targetDisplay)
    var origin = CGPoint(x: bounds.minX + 40, y: bounds.minY + 40)
    var size = CGSize(width: min(frame.width, bounds.width - 80), height: min(frame.height, bounds.height - 80))
    if let position = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    }
    if size != frame.size, let value = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}

// MARK: - Mission Control shortcuts

struct HotKey {
    let symbolic: Int32
    let keyCode: UInt16
    let flags: UInt32
}

/// "Switch to Desktop N" is symbolic hot key 118 + N - 1, for desktops 1 to 16.
func desktopHotKey(_ number: Int) -> HotKey? {
    guard (1...16).contains(number), let get = SLS.hotKeyValue else { return nil }
    let symbolic = Int32(118 + number - 1)
    var character: UInt16 = 0, keyCode: UInt16 = 0
    var flags: UInt32 = 0
    guard get(symbolic, &character, &keyCode, &flags) == 0, keyCode != 0xFFFF, keyCode != 0 || flags != 0 else { return nil }
    return HotKey(symbolic: symbolic, keyCode: keyCode, flags: flags)
}

func press(_ hotKey: HotKey) {
    let wasEnabled = SLS.hotKeyEnabled?(hotKey.symbolic) ?? true
    if !wasEnabled { _ = SLS.setHotKeyEnabled?(hotKey.symbolic, true) }
    let source = CGEventSource(stateID: .hidSystemState)
    let flags = CGEventFlags(rawValue: UInt64(hotKey.flags))
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(10_000)
    }
    if !wasEnabled { usleep(100_000); _ = SLS.setHotKeyEnabled?(hotKey.symbolic, false) }
}

/// Switch the screen to a space. Shortcut first; else raise a window there and let macOS follow it.
func switchTo(_ space: Space, raising window: FocusedWindow) -> Bool {
    if let number = space.number, let hotKey = desktopHotKey(number) {
        press(hotKey)
        if waitUntil(1.0, { activeSpaceID() == space.id }) {
            if let element = window.element { focus(element, pid: window.pid) }
            return true
        }
    }
    guard let element = window.element else { return false }
    focus(element, pid: window.pid)
    return waitUntil(1.0) { activeSpaceID() == space.id }
}

// MARK: - Moving

func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        usleep(20_000)
    } while Date() < deadline
    return condition()
}

func landed(_ window: CGWindowID, on target: UInt64, within timeout: TimeInterval = 0.4) -> Bool {
    waitUntil(timeout) { spaces(of: window).contains(target) }
}

private typealias MsgSendObject = @convention(c) (UnsafeRawPointer, Selector) -> UnsafeRawPointer?
private typealias MsgSendInitWindows = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer, UInt64) -> UnsafeRawPointer?
private typealias MsgSendVoid = @convention(c) (UnsafeRawPointer, Selector) -> Void

func moveBridged(_ window: CGWindowID, to target: UInt64) -> Bool {
    let perform = NSSelectorFromString("performWithWMBridgeDelegate")
    guard let cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation") as? AnyClass,
          class_respondsToSelector(cls, perform),
          let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
    else { return false }
    let sendObject = unsafeBitCast(send, to: MsgSendObject.self)
    let sendInit = unsafeBitCast(send, to: MsgSendInitWindows.self)
    let sendVoid = unsafeBitCast(send, to: MsgSendVoid.self)
    let windows = [NSNumber(value: window)] as NSArray
    autoreleasepool {
        let classPointer = UnsafeRawPointer(Unmanaged.passUnretained(cls as AnyObject).toOpaque())
        guard let allocated = sendObject(classPointer, NSSelectorFromString("alloc")) else { return }
        let windowsPointer = UnsafeRawPointer(Unmanaged.passUnretained(windows).toOpaque())
        guard let operation = sendInit(allocated, NSSelectorFromString("initWithWindows:spaceID:"), windowsPointer, target)
        else { return }
        sendVoid(operation, perform)  // = [SLSWMBridgeDelegate() performAsynchronousBridgedWindowManagementOperation:op]
        sendVoid(operation, NSSelectorFromString("release"))
    }
    withExtendedLifetime(windows) {}
    return landed(window, on: target, within: 1.5)  // asynchronous: allow it a moment
}

func moveDirect(_ window: CGWindowID, to target: UInt64) -> Bool {
    guard let move = SLS.moveWindows else { return false }
    move(SLS.cid, [NSNumber(value: window)] as CFArray, target)
    return landed(window, on: target)
}

func moveCompat(_ window: CGWindowID, to target: UInt64) -> Bool {
    guard let setCompat = SLS.setCompatID, let setWorkspace = SLS.setWorkspace else { return false }
    let tag: Int32 = 0x7961_6265
    var id = UInt32(window)
    _ = setCompat(SLS.cid, target, tag)
    _ = setWorkspace(SLS.cid, &id, 1, tag)
    _ = setCompat(SLS.cid, target, 0)
    return landed(window, on: target)
}

/// Hold the window by its title bar and switch desktops: macOS carries a dragged window along.
func moveByDragging(_ window: FocusedWindow, frame: CGRect?, to target: Space, from source: Space?) -> Bool {
    guard AXIsProcessTrusted(), let frame, let number = target.number, let hotKey = desktopHotKey(number) else { return false }
    let grab = CGPoint(x: frame.midX, y: frame.minY + 6)
    let saved = CGEvent(source: nil)?.location ?? grab
    func mouse(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    mouse(.mouseMoved, grab)
    usleep(30_000)
    mouse(.leftMouseDown, grab)
    usleep(80_000)
    mouse(.leftMouseDragged, CGPoint(x: grab.x + 1, y: grab.y))
    usleep(80_000)
    press(hotKey)
    _ = waitUntil(1.0) { activeSpaceID() == target.id }
    usleep(150_000)
    mouse(.leftMouseUp, CGPoint(x: grab.x + 1, y: grab.y))
    CGWarpMouseCursorPosition(saved)
    CGAssociateMouseAndMouseCursorPosition(1)
    if landed(window.id, on: target.id) { return true }
    // The grab missed (a tab, a button) but the screen still switched: take it back.
    if activeSpaceID() == target.id, let source, let number = source.number, let back = desktopHotKey(number) { press(back) }
    return false
}

struct MoveResult: Codable {
    let ok: Bool
    let method: String
    let app: String
    let window: CGWindowID
    let from: Space?
    let to: Space
    let followed: Bool
}

func move(to query: String, follow: Bool, method: String) throws -> MoveResult {
    let all = loadSpaces()
    guard !all.isEmpty else { throw Failure("Couldn't read Spaces from the WindowServer") }
    let target = try resolveTarget(query, in: all)
    if target.fullscreen { throw Failure("macOS won't move a window into a full-screen Space") }

    let window: FocusedWindow
    if let explicit = windowArgument {
        guard let owner = windowOwner(explicit) else { throw Failure("No window \(explicit)") }
        window = FocusedWindow(pid: owner, id: explicit, element: nil)
    } else if let focused = focusedWindow() {
        window = focused
    } else {
        throw Failure(AXIsProcessTrusted() ? "No focused window" : "No focused window (and no Accessibility permission)")
    }
    let sourceID = spaces(of: window.id).first
    let source = all.first(where: { $0.id == sourceID })
    if source?.fullscreen == true { throw Failure("macOS won't move a full-screen window between Spaces") }

    func result(_ method: String, followed: Bool) -> MoveResult {
        MoveResult(ok: true, method: method, app: window.appName, window: window.id, from: source, to: target, followed: followed)
    }
    if sourceID == target.id { return result("none", followed: false) }

    let frame = onScreenWindows().first(where: { $0.id == window.id })?.bounds
    placeOnDisplay(window, frame: frame, target: target)

    let routes: [(String, () -> Bool)] = [
        ("bridged", { moveBridged(window.id, to: target.id) }),
        ("direct", { moveDirect(window.id, to: target.id) }),
        ("compat", { moveCompat(window.id, to: target.id) }),
        ("drag", { moveByDragging(window, frame: frame, to: target, from: source) }),
    ]
    var tried: [String] = []
    // Drag moves the pointer and flips the screen, so it runs only when asked for by name.
    for (name, attempt) in routes where method == name || (method == "auto" && name != "drag") {
        tried.append(name)
        let ok = attempt()
        log(["window": window.id, "app": window.appName, "from": sourceID ?? 0, "to": target.id,
             "route": name, "ok": ok, "spacesAfter": spaces(of: window.id)])
        guard ok else { continue }
        if name == "drag" {
            // Dragging always takes the screen along; go back unless following.
            if !follow, let source, let number = source.number, let back = desktopHotKey(number) { press(back) }
            return result(name, followed: follow)
        }
        if follow { return result(name, followed: switchTo(target, raising: window)) }
        if windowArgument == nil { focusNextWindow(after: window.id, near: frame) }
        return result(name, followed: false)
    }
    var reason = "macOS didn't move the window (tried \(tried.joined(separator: ", ")))"
    if method == "drag" {
        if !AXIsProcessTrusted() { reason += "; drag needs Accessibility" }
        else if target.number.flatMap(desktopHotKey) == nil { reason += "; drag needs a \"Switch to Desktop \(target.number ?? 0)\" shortcut" }
    }
    throw Failure(reason)
}

/// One JSON line per attempt in ~/Library/Logs/spacemove.log, so a failure leaves evidence.
func log(_ fields: [String: Any]) {
    var entry = fields
    entry["time"] = ISO8601DateFormatter().string(from: Date())
    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/spacemove.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    handle.seekToEndOfFile()
    handle.write(data + Data("\n".utf8))
    try? handle.close()
}

// MARK: - CLI

struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
}

func doctor() {
    print("Accessibility trusted: \(AXIsProcessTrusted())")
    print("Connection: \(SLS.cid)")
    print("Symbols:")
    for (name, found) in SLS.all { print("  \(found ? "ok     " : "MISSING") \(name)") }
    print("Spaces:")
    for space in loadSpaces() {
        var keys = "-"
        if let number = space.number, let hotKey = desktopHotKey(number) {
            let enabled = SLS.hotKeyEnabled?(hotKey.symbolic) ?? false
            keys = "keyCode \(hotKey.keyCode) flags 0x\(String(hotKey.flags, radix: 16))\(enabled ? "" : " (disabled)")"
        } else if space.number != nil {
            keys = "no shortcut"
        }
        let marks = [space.current ? "current" : nil, space.active ? "active" : nil].compactMap { $0 }.joined(separator: ",")
        print("  [\(space.displayIndex)] id \(space.id)  \(space.title)  \(marks)  shortcut: \(keys)")
    }
}

_ = NSApplication.shared
var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
let follow = args.contains("--follow")
var method = "auto"
if let i = args.firstIndex(of: "--method"), i + 1 < args.count { method = args[i + 1]; args.removeSubrange(i...(i + 1)) }
var windowArgument: CGWindowID?
if let i = args.firstIndex(of: "--window"), i + 1 < args.count { windowArgument = CGWindowID(args[i + 1]); args.removeSubrange(i...(i + 1)) }
args.removeAll { $0.hasPrefix("--") }

do {
    switch args.first {
    case "list":
        let spaces = loadSpaces()
        if json { printJSON(spaces) } else {
            for space in spaces { print("\(space.active ? "*" : " ") \(space.title)\(space.displayIndex > 1 ? "  (display \(space.displayIndex))" : "")") }
        }
    case "move":
        guard args.count >= 2 else { throw Failure("usage: spacemove move <number | name | id:ID> [--follow]") }
        guard ["auto", "bridged", "direct", "compat", "drag"].contains(method) else {
            throw Failure("--method is auto, bridged, direct, compat or drag")
        }
        let result = try move(to: args.dropFirst().joined(separator: " "), follow: follow, method: method)
        if json { printJSON(result) } else { print("Moved \(result.app) to \(result.to.title) via \(result.method)") }
    case "doctor":
        doctor()
    default:
        throw Failure("usage: spacemove list [--json] | move <number | name | id:ID> [--follow] [--json] [--method M] | doctor")
    }
} catch let failure as Failure {
    if json {
        print("{\"ok\":false,\"error\":\(String(data: try! JSONEncoder().encode(failure.message), encoding: .utf8)!)}")
    } else {
        FileHandle.standardError.write((failure.message + "\n").data(using: .utf8)!)
    }
    exit(1)
}
