import Foundation

extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double) async throws {
        try await sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Sleeps for `seconds`; returns false instead of returning early silently when the task is cancelled,
/// so polling loops can stop rather than spin.
@discardableResult
func sleepUnlessCancelled(_ seconds: Double) async -> Bool {
    do {
        try await Task.sleep(seconds: seconds)
        return true
    } catch {
        return false
    }
}

/// Serialises restores: Space switching from two restores at once would fight over the displays.
actor RestoreLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
