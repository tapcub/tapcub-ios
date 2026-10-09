import Foundation

// Mirrors packages/app-sdk/src/core/types.ts. Keep field names and defaults in sync.

public struct TCReportPolicy: Sendable, Equatable {
    public var onLaunch: Bool = true
    public var onBackground: Bool = true
    public var intervalSec: Int = 30
    public var threshold: Int = 30
    public init(onLaunch: Bool = true, onBackground: Bool = true, intervalSec: Int = 30, threshold: Int = 30) {
        self.onLaunch = onLaunch
        self.onBackground = onBackground
        self.intervalSec = intervalSec
        self.threshold = threshold
    }
}

public struct TCQueueLimits: Sendable, Equatable {
    public var maxEvents: Int = 10000
    public var maxDays: Int = 7
    public var maxBatch: Int = 50
    public var maxBytes: Int = 65536
    public var maxStorageBytes: Int = 1_048_576
    public init(maxEvents: Int = 10000, maxDays: Int = 7, maxBatch: Int = 50, maxBytes: Int = 65536, maxStorageBytes: Int = 1_048_576) {
        self.maxEvents = maxEvents
        self.maxDays = maxDays
        self.maxBatch = maxBatch
        self.maxBytes = maxBytes
        self.maxStorageBytes = maxStorageBytes
    }
}

/// SDK configuration. Optional fields mean "not set" (same as `undefined` in the TS core).
public struct TapCubConfig: Sendable {
    public var siteKey: String
    public var endpoint: String?
    public var endpoints: [String]?
    public var appId: String?
    /// auto | eu | us | cn
    public var region: String?
    public var autoTrack: Bool?
    public var autoTrackScreens: Bool?
    public var crashReport: Bool?
    public var perf: Bool?
    public var reportPolicy: TCPartialPolicy?
    public var queue: TCPartialQueue?
    public var sessionTimeoutSec: Int?
    public var requireConsent: Bool?
    public var holdUntilIdentified: Bool?
    public var debug: Bool?
    public var deviceId: String?
    public var appName: String?
    public var appBuild: String?
    public var rejectCooldownDays: Int?
    public var appVersion: String?

    public init(
        siteKey: String,
        endpoint: String? = nil,
        endpoints: [String]? = nil,
        appId: String? = nil,
        region: String? = nil,
        autoTrack: Bool? = nil,
        autoTrackScreens: Bool? = nil,
        crashReport: Bool? = nil,
        perf: Bool? = nil,
        reportPolicy: TCPartialPolicy? = nil,
        queue: TCPartialQueue? = nil,
        sessionTimeoutSec: Int? = nil,
        requireConsent: Bool? = nil,
        holdUntilIdentified: Bool? = nil,
        debug: Bool? = nil,
        deviceId: String? = nil,
        appName: String? = nil,
        appBuild: String? = nil,
        rejectCooldownDays: Int? = nil,
        appVersion: String? = nil
    ) {
        self.siteKey = siteKey
        self.endpoint = endpoint
        self.endpoints = endpoints
        self.appId = appId
        self.region = region
        self.autoTrack = autoTrack
        self.autoTrackScreens = autoTrackScreens
        self.crashReport = crashReport
        self.perf = perf
        self.reportPolicy = reportPolicy
        self.queue = queue
        self.sessionTimeoutSec = sessionTimeoutSec
        self.requireConsent = requireConsent
        self.holdUntilIdentified = holdUntilIdentified
        self.debug = debug
        self.deviceId = deviceId
        self.appName = appName
        self.appBuild = appBuild
        self.rejectCooldownDays = rejectCooldownDays
        self.appVersion = appVersion
    }

    /// Builds a config from a JSON object (bridges and test vectors use the TS field names).
    public init(json o: JSONObject) {
        func s(_ k: String) -> String? { o[k]?.stringValue }
        func b(_ k: String) -> Bool? { o[k]?.boolValue }
        func i(_ k: String) -> Int? { o[k]?.numberValue.map { Int($0) } }
        self.init(siteKey: s("siteKey") ?? "")
        endpoint = s("endpoint")
        endpoints = o["endpoints"]?.arrayValue?.compactMap { $0.stringValue }
        appId = s("appId")
        region = s("region")
        autoTrack = b("autoTrack")
        autoTrackScreens = b("autoTrackScreens")
        crashReport = b("crashReport")
        perf = b("perf")
        if let p = o["reportPolicy"]?.objectValue {
            reportPolicy = TCPartialPolicy(
                onLaunch: p["onLaunch"]?.boolValue,
                onBackground: p["onBackground"]?.boolValue,
                intervalSec: p["intervalSec"]?.numberValue.map { Int($0) },
                threshold: p["threshold"]?.numberValue.map { Int($0) }
            )
        }
        if let q = o["queue"]?.objectValue {
            queue = TCPartialQueue(
                maxEvents: q["maxEvents"]?.numberValue.map { Int($0) },
                maxDays: q["maxDays"]?.numberValue.map { Int($0) },
                maxBatch: q["maxBatch"]?.numberValue.map { Int($0) },
                maxBytes: q["maxBytes"]?.numberValue.map { Int($0) },
                maxStorageBytes: q["maxStorageBytes"]?.numberValue.map { Int($0) }
            )
        }
        sessionTimeoutSec = i("sessionTimeoutSec")
        requireConsent = b("requireConsent")
        holdUntilIdentified = b("holdUntilIdentified")
        debug = b("debug")
        deviceId = s("deviceId")
        appName = s("appName")
        appBuild = s("appBuild")
        rejectCooldownDays = i("rejectCooldownDays")
        appVersion = s("appVersion")
    }
}

public struct TCPartialPolicy: Sendable {
    public var onLaunch: Bool?
    public var onBackground: Bool?
    public var intervalSec: Int?
    public var threshold: Int?
    public init(onLaunch: Bool? = nil, onBackground: Bool? = nil, intervalSec: Int? = nil, threshold: Int? = nil) {
        self.onLaunch = onLaunch
        self.onBackground = onBackground
        self.intervalSec = intervalSec
        self.threshold = threshold
    }
}

public struct TCPartialQueue: Sendable {
    public var maxEvents: Int?
    public var maxDays: Int?
    public var maxBatch: Int?
    public var maxBytes: Int?
    public var maxStorageBytes: Int?
    public init(maxEvents: Int? = nil, maxDays: Int? = nil, maxBatch: Int? = nil, maxBytes: Int? = nil, maxStorageBytes: Int? = nil) {
        self.maxEvents = maxEvents
        self.maxDays = maxDays
        self.maxBatch = maxBatch
        self.maxBytes = maxBytes
        self.maxStorageBytes = maxStorageBytes
    }
}

public struct TCRemoteConfig: Sendable, Equatable {
    public var enabled = true
    public var blacklist: [String] = []
    public var sample = 100
    public var interval = 30
    public var threshold = 30
    public var deviceBlacklist: [String] = []
    public var requireConsent = false
    public var autotrack = true
    public var textCapture = false
    public var elementBlacklist: [String] = []
    public var perf = false
    public var minVersion: String?
    public var ttl = 86400
    public init() {}

    public func toJSON() -> JSONObject {
        var o = JSONObject()
        o["enabled"] = .bool(enabled)
        o["blacklist"] = .array(blacklist.map { .string($0) })
        o["sample"] = .number(Double(sample))
        o["interval"] = .number(Double(interval))
        o["threshold"] = .number(Double(threshold))
        o["deviceBlacklist"] = .array(deviceBlacklist.map { .string($0) })
        o["requireConsent"] = .bool(requireConsent)
        o["autotrack"] = .bool(autotrack)
        o["textCapture"] = .bool(textCapture)
        o["elementBlacklist"] = .array(elementBlacklist.map { .string($0) })
        o["perf"] = .bool(perf)
        o["minVersion"] = minVersion.map { .string($0) } ?? .null
        o["ttl"] = .number(Double(ttl))
        return o
    }
}

/// Server cfg (GET /api/v1/pulse/cfg). `raw` is cached verbatim.
struct TCServerCfg {
    var raw: JSONValue
    var t: Double { raw["t"]?.numberValue ?? 2 }
    var i: Bool { truthy(raw["i"]) }
    var h: Bool { truthy(raw["h"]) }
    var cn: Bool { truthy(raw["cn"]) }
    var cs: JSONObject? { raw["cs"]?.objectValue }
    var rc: JSONValue? { raw["rc"] }

    static let conservative = TCServerCfg(raw: .object(["t": .number(2)]))
}

func truthy(_ v: JSONValue?) -> Bool {
    switch v {
    case .none, .some(.null): return false
    case .some(.bool(let b)): return b
    case .some(.number(let n)): return n != 0 && !n.isNaN
    case .some(.string(let s)): return !s.isEmpty
    default: return true
    }
}

public struct TCTransportResponse: Sendable {
    public var status: Int
    public var body: String?
    public init(status: Int, body: String? = nil) {
        self.status = status
        self.body = body
    }
}

public struct TCLaunchInfo: Sendable {
    public var scene: JSONValue?
    public var path: String?
    public var query: [String: String]
    public init(scene: JSONValue? = nil, path: String? = nil, query: [String: String] = [:]) {
        self.scene = scene
        self.path = path
        self.query = query
    }
}

public struct TCPageInfo: Sendable, Equatable {
    public var path: String
    public var query: [String: String]?
    public var title: String?
    public init(path: String, query: [String: String]? = nil, title: String? = nil) {
        self.path = path
        self.query = query
        self.title = title
    }
}

public struct TCElement: Sendable {
    public var type: String?
    public var id: String?
    public var content: String?
    public var path: String?
    public init(type: String? = nil, id: String? = nil, content: String? = nil, path: String? = nil) {
        self.type = type
        self.id = id
        self.content = content
        self.path = path
    }
}

public struct TCCrashEvent: Sendable {
    /// crash | anr | freeze
    public var kind: String
    public var type: String?
    public var message: String?
    public var stack: String?
    public var fatal: Bool?
    public var durationMs: Int?
    public var foreground: Bool?
    /// Crash time in ms; kept when the crash is reported on the next launch.
    public var ts: Int64?
    public init(kind: String, type: String? = nil, message: String? = nil, stack: String? = nil, fatal: Bool? = nil, durationMs: Int? = nil, foreground: Bool? = nil, ts: Int64? = nil) {
        self.kind = kind
        self.type = type
        self.message = message
        self.stack = stack
        self.fatal = fatal
        self.durationMs = durationMs
        self.foreground = foreground
        self.ts = ts
    }
}

public struct TCDeviceSnapshot: Sendable {
    public var os: String?
    public var osVersion: String?
    public var brand: String?
    public var model: String?
    /// phone | tablet | tv | other
    public var deviceType: String?
    public var screenWidth: Int?
    public var screenHeight: Int?
    public var pixelRatio: Double?
    public var locale: String?
    public var timezone: String?
    public var hostVersion: String?
    public init(os: String? = nil, osVersion: String? = nil, brand: String? = nil, model: String? = nil, deviceType: String? = nil, screenWidth: Int? = nil, screenHeight: Int? = nil, pixelRatio: Double? = nil, locale: String? = nil, timezone: String? = nil, hostVersion: String? = nil) {
        self.os = os
        self.osVersion = osVersion
        self.brand = brand
        self.model = model
        self.deviceType = deviceType
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.pixelRatio = pixelRatio
        self.locale = locale
        self.timezone = timezone
        self.hostVersion = hostVersion
    }
    var isEmpty: Bool { os == nil && model == nil && screenWidth == nil && locale == nil && osVersion == nil }
}

public struct TCLifecycleHandlers {
    public var onLaunch: (TCLaunchInfo) -> Void
    public var onShow: (TCLaunchInfo) -> Void
    public var onHide: () -> Void
    public var onPageShow: (TCPageInfo) -> Void
    public var onPageHide: (TCPageInfo) -> Void
    public var onShare: (TCPageInfo, String) -> Void
}

// MARK: - adapter protocols (six protocols + optional hooks)

public protocol TCStorage: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String) throws
    func remove(_ key: String)
}

public protocol TCTransport: AnyObject {
    /// Network errors are reported as `.failure`.
    func get(_ url: String, completion: @escaping (Result<TCTransportResponse, Error>) -> Void)
    func post(_ url: String, body: String, headers: [String: String], completion: @escaping (Result<TCTransportResponse, Error>) -> Void)
}

public protocol TCLifecycle: AnyObject {
    func bind(_ handlers: TCLifecycleHandlers)
}

public protocol TCDeviceInfo: AnyObject {
    /// android | ios | harmony
    var platform: String { get }
    /// Only called after consent (or when the site does not require consent).
    func read() -> TCDeviceSnapshot
    func networkType(_ completion: @escaping (String?) -> Void)
    /// Full platform device id such as `ios_idfv:<uuid>`; nil lets the core generate one. Only called after consent.
    func deviceId() -> String?
}

public extension TCDeviceInfo {
    func deviceId() -> String? { nil }
}

public protocol TCTimers: AnyObject {
    func now() -> Int64
    func setTimeout(_ ms: Int64, _ fn: @escaping () -> Void) -> Int
    func clearTimeout(_ id: Int)
    func setInterval(_ ms: Int64, _ fn: @escaping () -> Void) -> Int
    func clearInterval(_ id: Int)
    func random() -> Double
}

public protocol TCAutoTrackHook: AnyObject {
    func enable(_ cb: @escaping (TCElement, TCPageInfo?) -> Void)
    func disable()
}

public protocol TCCrashHook: AnyObject {
    func enable(_ cb: @escaping (TCCrashEvent) -> Void)
    func disable()
}

public struct TCAdapters {
    public var storage: TCStorage
    public var transport: TCTransport
    public var lifecycle: TCLifecycle
    public var device: TCDeviceInfo
    public var timers: TCTimers
    public var autoTrack: TCAutoTrackHook?
    public var crash: TCCrashHook?
    public var log: ((String, String) -> Void)?
    public init(storage: TCStorage, transport: TCTransport, lifecycle: TCLifecycle, device: TCDeviceInfo, timers: TCTimers, autoTrack: TCAutoTrackHook? = nil, crash: TCCrashHook? = nil, log: ((String, String) -> Void)? = nil) {
        self.storage = storage
        self.transport = transport
        self.lifecycle = lifecycle
        self.device = device
        self.timers = timers
        self.autoTrack = autoTrack
        self.crash = crash
        self.log = log
    }
}

public struct TCState: Sendable {
    public var initialized: Bool
    public var deviceId: String?
    public var sessionId: String?
    public var consent: Int?
    public var optedOut: Bool
    public var loginId: String?
    public var loginType: String?
    public var queueLength: Int
    public var holdLength: Int
    public var enabled: Bool
    public var sampled: Bool
    public var tier: Double
    public var endpoint: String
    public var sessionCount: Int

    public func toJSON() -> JSONObject {
        func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
        var o = JSONObject()
        o["initialized"] = .bool(initialized)
        o["deviceId"] = opt(deviceId)
        o["sessionId"] = opt(sessionId)
        o["consent"] = consent.map { .number(Double($0)) } ?? .null
        o["optedOut"] = .bool(optedOut)
        o["loginId"] = opt(loginId)
        o["loginType"] = opt(loginType)
        o["queueLength"] = .number(Double(queueLength))
        o["holdLength"] = .number(Double(holdLength))
        o["enabled"] = .bool(enabled)
        o["sampled"] = .bool(sampled)
        o["tier"] = .number(tier)
        o["endpoint"] = .string(endpoint)
        o["sessionCount"] = .number(Double(sessionCount))
        return o
    }
}
