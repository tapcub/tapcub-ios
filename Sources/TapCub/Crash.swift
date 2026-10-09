import Foundation
#if canImport(TapCubCore)
import TapCubCore
#endif
#if canImport(TapCubCrashC)
import TapCubCrashC
#endif
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// Crash capture. Nothing is sent while the process dies: NSException records are written as JSON and
/// signals are written by the C handler (`tapcub_crash.c`); both are reported on the next launch with the
/// original crash time. Previously installed handlers are always chained.
public final class TCCrashReporter: TCCrashHook {
    private let queue: DispatchQueue
    private let dir: URL
    private var watchdog: TCFreezeWatchdog?
    private var enabled = false
    public var freezeThresholdMs: Int64 = 2000

    public init(queue: DispatchQueue, directory: URL? = nil) {
        self.queue = queue
        dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(TapCubBrand.supportDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var exceptionFile: URL { dir.appendingPathComponent("tapcub_crash_exception.json") }
    var signalFile: URL { dir.appendingPathComponent("tapcub_crash_signal.log") }
    var recentFile: URL { dir.appendingPathComponent("tapcub_crash_recent.json") }

    public func enable(_ cb: @escaping (TCCrashEvent) -> Void) {
        if enabled { return }
        enabled = true
        let pending = consumePending()
        if !pending.isEmpty {
            rememberRecent(pending)
            queue.async { pending.forEach(cb) }
        }
        TCExceptionHandler.install(path: exceptionFile.path)
        _ = tapcub_crash_install(signalFile.path)
        let dog = TCFreezeWatchdog(thresholdMs: freezeThresholdMs) { [queue] ms in
            queue.async { cb(TCCrashEvent(kind: "freeze", type: "UIFreeze", message: "main thread blocked", fatal: false, durationMs: Int(ms), foreground: true)) }
        }
        dog.start()
        watchdog = dog
        #if canImport(MetricKit) && os(iOS)
        if #available(iOS 14.0, *) {
            TCMetricKit.shared.start(reporter: self) { [queue] ev in queue.async { cb(ev) } }
        }
        #endif
    }

    public func disable() {
        if !enabled { return }
        enabled = false
        watchdog?.stop()
        watchdog = nil
        tapcub_crash_uninstall()
        TCExceptionHandler.uninstall()
    }

    /// Reads and deletes records left by the previous process.
    func consumePending() -> [TCCrashEvent] {
        var out: [TCCrashEvent] = []
        if let data = try? Data(contentsOf: exceptionFile),
           let o = JSONValue.parse(String(decoding: data, as: UTF8.self))?.objectValue {
            out.append(TCCrashEvent(
                kind: "crash",
                type: o["type"]?.stringValue,
                message: o["message"]?.stringValue,
                stack: o["stack"]?.stringValue,
                fatal: true,
                foreground: o["foreground"]?.boolValue,
                ts: o["ts"]?.numberValue.map { Int64($0) }
            ))
        }
        try? FileManager.default.removeItem(at: exceptionFile)
        if let text = try? String(contentsOf: signalFile, encoding: .utf8), let ev = Self.parseSignalRecord(text) {
            out.append(ev)
        }
        // the C handler truncates the file when it is installed again
        return out
    }

    static func parseSignalRecord(_ text: String) -> TCCrashEvent? {
        let lines = text.split(separator: "\n").map(String.init)
        guard let head = lines.first, head.hasPrefix("TCSIG ") else { return nil }
        let parts = head.split(separator: " ")
        guard parts.count >= 3, let sig = Int32(parts[1]), let sec = Int64(parts[2]) else { return nil }
        let name = signalName(sig)
        return TCCrashEvent(kind: "crash", type: name, message: "signal \(sig)", stack: lines.dropFirst().joined(separator: "\n"), fatal: true, foreground: true, ts: sec * 1000)
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(sig)"
        }
    }

    /// Crash times already reported by this SDK, used to drop the matching MetricKit diagnostic.
    func rememberRecent(_ events: [TCCrashEvent]) {
        var list = recent()
        for e in events { if let ts = e.ts { list.append((ts, e.type ?? "")) } }
        let arr: [JSONValue] = list.suffix(20).map { .object(["ts": .number(Double($0.ts)), "type": .string($0.type)]) }
        try? Data(JSONValue.array(arr).stringify().utf8).write(to: recentFile, options: .atomic)
    }

    func recent() -> [(ts: Int64, type: String)] {
        guard let text = try? String(contentsOf: recentFile, encoding: .utf8), let arr = JSONValue.parse(text)?.arrayValue else { return [] }
        return arr.compactMap { v in
            guard let ts = v["ts"]?.numberValue else { return nil }
            return (Int64(ts), v["type"]?.stringValue ?? "")
        }
    }
}

/// NSException handler (C function pointer, so state is global). Writes JSON synchronously, tells the
/// signal handler to skip the abort that follows, then calls the previous handler.
enum TCExceptionHandler {
    nonisolated(unsafe) static var path = ""
    nonisolated(unsafe) static var previous: (@convention(c) (NSException) -> Void)?
    nonisolated(unsafe) static var installed = false

    static func install(path p: String) {
        if installed { return }
        installed = true
        path = p
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { ex in
            TCExceptionHandler.record(ex)
            TCExceptionHandler.previous?(ex)
        }
    }

    static func uninstall() {
        if !installed { return }
        installed = false
        NSSetUncaughtExceptionHandler(previous)
    }

    static func record(_ ex: NSException) {
        var o = JSONObject()
        o["type"] = .string(ex.name.rawValue)
        o["message"] = .string(ex.reason ?? "")
        o["stack"] = .string(ex.callStackSymbols.joined(separator: "\n"))
        o["ts"] = .number((Date().timeIntervalSince1970 * 1000).rounded())
        o["foreground"] = .bool(true)
        try? Data(o.stringify().utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        tapcub_crash_mark_handled()
    }
}

/// Pings the main queue every 500 ms from a utility queue; a reply that arrives later than the
/// threshold is reported once, with the measured block duration.
final class TCFreezeWatchdog {
    private let thresholdMs: Int64
    private let onFreeze: (Int64) -> Void
    private let q = DispatchQueue(label: "com.tapcub.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var waiting = false

    init(thresholdMs: Int64, onFreeze: @escaping (Int64) -> Void) {
        self.thresholdMs = thresholdMs
        self.onFreeze = onFreeze
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if waiting { return }
        waiting = true
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            let ms = Int64((DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
            self?.q.async {
                guard let self else { return }
                self.waiting = false
                if ms >= self.thresholdMs { self.onFreeze(ms) }
            }
        }
    }
}

#if canImport(MetricKit) && os(iOS)
/// MetricKit diagnostics fill the gaps of in-process capture (watchdog kills, hangs the app never
/// recovered from). A crash diagnostic is dropped when the signal path already reported the same
/// signal inside the diagnostic's time window.
@available(iOS 14.0, *)
final class TCMetricKit: NSObject, MXMetricManagerSubscriber {
    static let shared = TCMetricKit()
    private weak var reporter: TCCrashReporter?
    private var cb: ((TCCrashEvent) -> Void)?

    func start(reporter: TCCrashReporter, cb: @escaping (TCCrashEvent) -> Void) {
        self.reporter = reporter
        self.cb = cb
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let recent = reporter?.recent() ?? []
        for payload in payloads {
            let begin = Int64(payload.timeStampBegin.timeIntervalSince1970 * 1000)
            let end = Int64(payload.timeStampEnd.timeIntervalSince1970 * 1000)
            for d in payload.crashDiagnostics ?? [] {
                let sig = d.signal.map { TCCrashReporter.signalName($0.int32Value) } ?? "MXCrash"
                if recent.contains(where: { $0.type == sig && $0.ts >= begin && $0.ts <= end }) { continue }
                let stack = String(decoding: d.callStackTree.jsonRepresentation(), as: UTF8.self)
                cb?(TCCrashEvent(kind: "crash", type: sig, message: d.terminationReason ?? d.virtualMemoryRegionInfo ?? "metrickit", stack: stack, fatal: true, foreground: true, ts: end))
            }
            for h in payload.hangDiagnostics ?? [] {
                let ms = Int(h.hangDuration.converted(to: .milliseconds).value)
                let stack = String(decoding: h.callStackTree.jsonRepresentation(), as: UTF8.self)
                cb?(TCCrashEvent(kind: "freeze", type: "MXHang", message: "metrickit", stack: stack, fatal: false, durationMs: ms, foreground: true, ts: end))
            }
        }
    }
}
#endif
