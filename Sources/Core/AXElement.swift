import AppKit
import ApplicationServices

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Hung apps would otherwise block AX calls for the default 6 seconds.
    static func configureGlobalTimeout(seconds: Float = 1.0) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func isError(_ value: CFTypeRef) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError
    }
}

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }

    func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        guard let value = value(attribute), let array = value as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    /// Fetches several attributes in one round trip. Missing attributes are absent from the result.
    func values(_ attributes: [String]) -> [String: CFTypeRef] {
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(self, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard error == .success, let array = raw as? [AnyObject], array.count == attributes.count else { return [:] }
        var result: [String: CFTypeRef] = [:]
        for (name, value) in zip(attributes, array) where !(value is NSNull) && !AX.isError(value) {
            result[name] = value
        }
        return result
    }

    var position: CGPoint? { AX.point(value(kAXPositionAttribute)) }
    var size: CGSize? { AX.size(value(kAXSizeAttribute)) }

    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    var windowID: CGWindowID? { PrivateAPI.windowID(of: self) }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return set(kAXPositionAttribute, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return set(kAXSizeAttribute, value) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }
}

/// Serial queue for Accessibility work: AX calls are synchronous IPC and can stall on unresponsive apps,
/// so they never run on the main thread.
final class AXWorker: @unchecked Sendable {
    static let shared = AXWorker()
    let queue = DispatchQueue(label: "com.vivapercuore.StayWhereWindowsAre.ax", qos: .userInitiated)

    func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
