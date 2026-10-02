import Foundation

/// Bounded, blocking stdin for an interactive guest. Cancellation is polled while waiting.
public final class ProgramInput: @unchecked Sendable {
    private let condition = NSCondition()
    private var bytes: [UInt8] = []
    private var received = 0
    private var ended = false
    public init() {}

    @discardableResult public func send(_ text: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !ended, text.utf8.count <= 64 * 1024 - received else { return false }
        let incoming = Array(text.utf8)
        bytes += incoming; received += incoming.count
        condition.broadcast()
        return true
    }
    public func finish() {
        condition.lock(); ended = true; condition.broadcast(); condition.unlock()
    }
    func read(maxCount: Int, cancellation: Cancellation, waiting: @Sendable (Bool) -> Void) throws -> [UInt8] {
        guard maxCount > 0 else { return [] }
        condition.lock()
        var announced = false
        defer { condition.unlock(); if announced { waiting(false) } }
        while bytes.isEmpty && !ended && !cancellation.isCancelled {
            if !announced {
                announced = true
                condition.unlock(); waiting(true); condition.lock()
                continue
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        if cancellation.isCancelled { throw PrototypeError.message("Stopped.") }
        let result = Array(bytes.prefix(maxCount))
        bytes.removeFirst(result.count)
        return result
    }
}

public struct RunEvents: Sendable {
    public var onRunning: @Sendable () -> Void
    public var onOutput: @Sendable (String) -> Void
    public var onWaitingForInput: @Sendable (Bool) -> Void
    public init(onRunning: @escaping @Sendable () -> Void = {},
                onOutput: @escaping @Sendable (String) -> Void = { _ in },
                onWaitingForInput: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.onRunning = onRunning; self.onOutput = onOutput; self.onWaitingForInput = onWaitingForInput
    }
}
