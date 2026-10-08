import AppKit
import ApplicationServices

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// Undocumented WindowServer / HIServices entry points, resolved at runtime with dlsym so that a symbol
/// disappearing in a future macOS release degrades a feature instead of preventing launch.
enum PrivateAPI {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)

    private static func resolve<T>(_ handle: UnsafeMutableRawPointer?, _ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let pointer = dlsym(handle, name) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(pointer, to: type)
            }
        }
        return nil
    }

    private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CurrentSpaceFn = @convention(c) (CGSConnectionID, CFString) -> CGSSpaceID
    private typealias MoveWindowsToSpaceFn = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXCreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let mainConnectionFn = resolve(skyLight, ["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFn.self)
    private static let copyManagedDisplaySpacesFn = resolve(
        skyLight, ["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyManagedDisplaySpacesFn.self)
    private static let copySpacesForWindowsFn = resolve(
        skyLight, ["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindowsFn.self)
    private static let currentSpaceFn = resolve(
        skyLight, ["SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"], as: CurrentSpaceFn.self)
    private static let moveWindowsToSpaceFn = resolve(
        skyLight, ["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"], as: MoveWindowsToSpaceFn.self)
    private static let setFrontProcessFn = resolve(skyLight, ["_SLPSSetFrontProcessWithOptions"], as: SetFrontProcessFn.self)
    private static let postEventRecordFn = resolve(skyLight, ["SLPSPostEventRecordTo"], as: PostEventRecordFn.self)
    private static let getProcessForPIDFn = resolve(hiServices, ["GetProcessForPID"], as: GetProcessForPIDFn.self)
    private static let axGetWindowFn = resolve(hiServices, ["_AXUIElementGetWindow"], as: AXGetWindowFn.self)
    private static let axCreateWithRemoteTokenFn = resolve(
        hiServices, ["_AXUIElementCreateWithRemoteToken"], as: AXCreateWithRemoteTokenFn.self)

    static let connection: CGSConnectionID = mainConnectionFn?() ?? 0

    static var availability: [(name: String, available: Bool)] {
        [
            ("SLSMainConnectionID", mainConnectionFn != nil),
            ("SLSCopyManagedDisplaySpaces", copyManagedDisplaySpacesFn != nil),
            ("SLSCopySpacesForWindows", copySpacesForWindowsFn != nil),
            ("SLSManagedDisplayGetCurrentSpace", currentSpaceFn != nil),
            ("SLSMoveWindowsToManagedSpace", moveWindowsToSpaceFn != nil),
            ("_SLPSSetFrontProcessWithOptions", setFrontProcessFn != nil),
            ("SLPSPostEventRecordTo", postEventRecordFn != nil),
            ("GetProcessForPID", getProcessForPIDFn != nil),
            ("_AXUIElementGetWindow", axGetWindowFn != nil),
            ("_AXUIElementCreateWithRemoteToken", axCreateWithRemoteTokenFn != nil),
        ]
    }

    static var spacesAvailable: Bool { copyManagedDisplaySpacesFn != nil && copySpacesForWindowsFn != nil && connection != 0 }

    static func copyManagedDisplaySpaces() -> [[String: Any]] {
        guard let fn = copyManagedDisplaySpacesFn, connection != 0 else { return [] }
        return fn(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// Spaces the window belongs to. More than one entry means the window is visible on all Spaces.
    static func spaces(forWindow windowID: CGWindowID) -> [CGSSpaceID] {
        guard let fn = copySpacesForWindowsFn, connection != 0 else { return [] }
        let ids = [NSNumber(value: windowID)] as CFArray
        let result = fn(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] ?? []
        return result.map { $0.uint64Value }
    }

    static func currentSpace(displayIdentifier: String) -> CGSSpaceID? {
        guard let fn = currentSpaceFn, connection != 0 else { return nil }
        let space = fn(connection, displayIdentifier as CFString)
        return space == 0 ? nil : space
    }

    /// Only effective for windows owned by this process (macOS 14.5+ silently ignores foreign windows).
    static func moveOwnWindow(_ windowID: CGWindowID, toSpace space: CGSSpaceID) {
        guard let fn = moveWindowsToSpaceFn, connection != 0 else { return }
        fn(connection, [NSNumber(value: windowID)] as CFArray, space)
    }

    static func processSerialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        guard let fn = getProcessForPIDFn else { return nil }
        var psn = ProcessSerialNumber()
        return fn(pid, &psn) == noErr ? psn : nil
    }

    /// Brings the process to the front with the given window as its key window, switching Spaces if needed.
    /// Mirrors what window switchers do; works across Spaces where `NSRunningApplication.activate` does not.
    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFront = setFrontProcessFn, var psn = processSerialNumber(for: pid) else { return false }
        let userGenerated: UInt32 = 0x200
        let result = setFront(&psn, windowID, userGenerated)
        if let post = postEventRecordFn {
            for kind: UInt8 in [0x01, 0x02] {
                var bytes = [UInt8](repeating: 0, count: 0xF8)
                bytes[0x04] = 0xF8
                bytes[0x08] = kind
                bytes[0x3A] = 0x10
                bytes.withUnsafeMutableBytes { raw in
                    for offset in 0x20..<0x30 { raw[offset] = 0xFF }
                    raw.storeBytes(of: windowID, toByteOffset: 0x3C, as: UInt32.self)
                }
                _ = post(&psn, &bytes)
            }
        }
        return result == 0
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindowFn else { return nil }
        var windowID: CGWindowID = 0
        return fn(element, &windowID) == .success && windowID != 0 ? windowID : nil
    }

    static var canCreateRemoteElements: Bool { axCreateWithRemoteTokenFn != nil }

    /// Builds an AX element for `pid` by its internal element id. Used to reach windows on other Spaces,
    /// which `kAXWindowsAttribute` does not report.
    static func remoteElement(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let fn = axCreateWithRemoteTokenFn else { return nil }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636F_636F), toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
        }
        return fn(token as CFData)?.takeRetainedValue()
    }
}
