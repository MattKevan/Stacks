import Foundation

/// A small counting semaphore for capping concurrent background work.
///
/// Used to throttle remote cover fetches: a grid spawns one request per visible
/// tile, and without a limit they all start at once, saturating the connection
/// and delaying the sync pull that refreshes the list.
///
/// An actor rather than `DispatchSemaphore`: awaiting must not block a thread,
/// and the permit accounting has to be race-free under Swift concurrency.
actor AsyncGate {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspends until a slot is free.
    func wait() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases a slot, resuming the longest-waiting caller.
    func signal() {
        if waiters.isEmpty {
            inFlight = max(0, inFlight - 1)
        } else {
            // Hand the slot straight to the next waiter rather than
            // decrementing and re-incrementing (which would let a fresh caller
            // jump the queue).
            waiters.removeFirst().resume()
        }
    }
}
