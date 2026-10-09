import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One `$fps_sample` + `$memory_sample` per session when `perf` is on (config or `rc.perf`).
/// Field names match what the backend aggregates (`$fps_avg`, `$fps_min`, `$jank_pct`, `$memory_mb`).
enum TCPerfSampler {
    /// Samples the display link for `seconds` on the main thread, then calls back with both payloads.
    static func sample(seconds: Double = 10, _ done: @escaping (_ fps: [String: Any]?, _ memory: [String: Any]?) -> Void) {
        #if canImport(UIKit) && !os(watchOS)
        DispatchQueue.main.async {
            let probe = FrameProbe(seconds: seconds) { fps in done(fps, memorySample()) }
            probe.start()
        }
        #else
        done(nil, memorySample())
        #endif
    }

    static func memorySample() -> [String: Any]? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return ["$memory_mb": Int(info.phys_footprint / 1_048_576)]
    }

    #if canImport(UIKit) && !os(watchOS)
    private final class FrameProbe: NSObject {
        private let seconds: Double
        private let done: ([String: Any]?) -> Void
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var startAt: CFTimeInterval = 0
        private var frames = 0
        private var janks = 0
        private var secondStart: CFTimeInterval = 0
        private var secondFrames = 0
        private var minFps = Int.max
        private var expected: CFTimeInterval = 1.0 / 60
        private static var retained = Set<FrameProbe>()

        init(seconds: Double, done: @escaping ([String: Any]?) -> Void) {
            self.seconds = seconds
            self.done = done
        }

        func start() {
            FrameProbe.retained.insert(self)
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func tick(_ l: CADisplayLink) {
            let t = l.timestamp
            if startAt == 0 {
                startAt = t
                secondStart = t
                last = t
                if #available(iOS 15.0, tvOS 15.0, *), l.targetTimestamp > t { expected = l.targetTimestamp - t }
                return
            }
            frames += 1
            secondFrames += 1
            if t - last > expected * 1.5 { janks += 1 }
            last = t
            if t - secondStart >= 1 {
                minFps = min(minFps, secondFrames)
                secondFrames = 0
                secondStart = t
            }
            if t - startAt >= seconds { finish(elapsed: t - startAt) }
        }

        private func finish(elapsed: CFTimeInterval) {
            link?.invalidate()
            link = nil
            FrameProbe.retained.remove(self)
            guard frames > 0, elapsed > 0 else { done(nil); return }
            let avg = (Double(frames) / elapsed * 10).rounded() / 10
            let jank = (Double(janks) / Double(frames) * 1000).rounded() / 10
            done(["$fps_avg": avg, "$fps_min": minFps == Int.max ? Int(avg) : minFps, "$jank_pct": jank])
        }
    }
    #endif
}
