import Foundation
#if canImport(TapCubCore)
import TapCubCore
#endif

/// Crash capture without the analytics core, for hosts whose core runs elsewhere (the React Native bridge runs
/// the TS core in JS). Records are kept until `drain()` hands them over; do not combine with
/// `TapCub.preInit`, which captures crashes itself.
@objc(TapCubCrash)
public final class TapCubCrash: NSObject {
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: TapCubBrand.workerQueue + ".crash")
    nonisolated(unsafe) private static var reporter: TCCrashReporter?
    nonisolated(unsafe) private static var pending: [TCCrashEvent] = []

    /// Call from `application(_:didFinishLaunchingWithOptions:)` so startup crashes are caught too. Idempotent.
    @objc public static func install() {
        lock.lock()
        defer { lock.unlock() }
        if reporter != nil { return }
        let r = TCCrashReporter(queue: queue)
        reporter = r
        r.enable { ev in
            lock.lock()
            pending.append(ev)
            lock.unlock()
        }
    }

    /// Crashes and freezes recorded on earlier launches; each one is returned once.
    @objc public static func drain() -> [[String: Any]] {
        queue.sync {}
        lock.lock()
        let out = pending
        pending.removeAll()
        lock.unlock()
        return out.map { ev in
            var m: [String: Any] = ["kind": ev.kind]
            if let v = ev.type { m["type"] = v }
            if let v = ev.message { m["message"] = v }
            if let v = ev.stack { m["stack"] = v }
            if let v = ev.fatal { m["fatal"] = v }
            if let v = ev.durationMs { m["durationMs"] = v }
            if let v = ev.foreground { m["foreground"] = v }
            if let v = ev.ts { m["ts"] = v }
            return m
        }
    }
}
