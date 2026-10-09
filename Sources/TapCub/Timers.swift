import Foundation
#if canImport(TapCubCore)
import TapCubCore
#endif

/// Wall clock + secure random + timers on the worker queue. Must only be used from that queue.
public final class TCDispatchTimers: TCTimers {
    private let queue: DispatchQueue
    private var seq = 0
    private var items: [Int: DispatchWorkItem] = [:]
    private var sources: [Int: DispatchSourceTimer] = [:]
    private var rng = SystemRandomNumberGenerator()

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    public func random() -> Double { Double.random(in: 0..<1, using: &rng) }

    public func setTimeout(_ ms: Int64, _ fn: @escaping () -> Void) -> Int {
        seq += 1
        let id = seq
        let item = DispatchWorkItem { [weak self] in
            self?.items.removeValue(forKey: id)
            fn()
        }
        items[id] = item
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms))), execute: item)
        return id
    }

    public func clearTimeout(_ id: Int) {
        items.removeValue(forKey: id)?.cancel()
    }

    public func setInterval(_ ms: Int64, _ fn: @escaping () -> Void) -> Int {
        seq += 1
        let id = seq
        let every = DispatchTimeInterval.milliseconds(Int(max(1, ms)))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + every, repeating: every, leeway: .seconds(1))
        t.setEventHandler(handler: fn)
        t.resume()
        sources[id] = t
        return id
    }

    public func clearInterval(_ id: Int) {
        sources.removeValue(forKey: id)?.cancel()
    }
}
