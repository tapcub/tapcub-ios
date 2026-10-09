import Foundation
@testable import TapCubCore

// Swift port of packages/app-sdk/test/{mock,runner}.mjs. Same vectors, same matcher tokens.

struct VectorError: Error, CustomStringConvertible { let description: String }

final class VectorMock {
    let start: Int64
    var now: Int64
    var seq = 0
    var timers: [Int: (at: Int64, fn: () -> Void, every: Int64)] = [:]
    var deferred: [() -> Void] = []
    let rng: Mulberry32

    var store: [String: String]
    var storageFail = false

    var cfgScript: JSONValue
    var collect: JSONValue
    var collectSeq: [JSONValue]?
    var requests: [(url: String, body: JSONValue?, at: Int64, bytes: Int)] = []
    var cfgRequests = 0

    var handlers: TCLifecycleHandlers?
    var deviceReads = 0
    var autoCb: ((TCElement, TCPageInfo?) -> Void)?
    var crashCb: ((TCCrashEvent) -> Void)?
    let platform: String
    let nativeDeviceId: String?

    init(_ v: JSONObject) {
        nativeDeviceId = v["nativeDeviceId"]?.stringValue
        start = Int64(v["now"]?.numberValue ?? 1_700_000_000_000)
        now = start
        rng = Mulberry32(seed: UInt32(v["seed"]?.numberValue ?? 42))
        var s: [String: String] = [:]
        v["storage"]?.objectValue?.forEach { k, val in s[k] = val.stringValue ?? val.stringify() }
        store = s
        cfgScript = v["cfg"] ?? .object(["t": .number(3), "i": .number(1), "cs": .object(["req": .bool(false)])])
        collect = v["collect"] ?? .number(202)
        collectSeq = v["collect"]?.arrayValue
        platform = v["platform"]?.stringValue ?? "android"
    }

    func drain() {
        var guardCount = 0
        while !deferred.isEmpty && guardCount < 100_000 {
            let f = deferred.removeFirst()
            f()
            guardCount += 1
        }
    }

    func advance(_ ms: Int64) {
        let target = now + ms
        while true {
            let due = timers.filter { $0.value.at <= target }.sorted { a, b in a.value.at != b.value.at ? a.value.at < b.value.at : a.key < b.key }
            guard let next = due.first else { break }
            now = max(now, next.value.at)
            if next.value.every > 0 {
                timers[next.key]?.at += next.value.every
            } else {
                timers.removeValue(forKey: next.key)
            }
            next.value.fn()
            drain()
        }
        now = target
        drain()
    }

    func respond(_ script: JSONValue, _ completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
        let r: Result<TCTransportResponse, Error>
        switch script {
        case .string("fail"): r = .failure(VectorError(description: "network"))
        case .number(let n): r = .success(TCTransportResponse(status: Int(n), body: ""))
        default: r = .success(TCTransportResponse(status: 200, body: script.stringify()))
        }
        deferred.append { completion(r) }
    }

    func adapters() -> TCAdapters {
        TCAdapters(
            storage: MStorage(self),
            transport: MTransport(self),
            lifecycle: MLifecycle(self),
            device: MDevice(self),
            timers: MTimers(self),
            autoTrack: MAutoTrack(self),
            crash: MCrash(self)
        )
    }

    final class MStorage: TCStorage {
        unowned let m: VectorMock
        init(_ m: VectorMock) { self.m = m }
        func get(_ key: String) -> String? { m.store[key] }
        func set(_ key: String, _ value: String) throws {
            if m.storageFail { throw VectorError(description: "storage quota") }
            m.store[key] = value
        }
        func remove(_ key: String) { m.store.removeValue(forKey: key) }
    }

    final class MTransport: TCTransport {
        unowned let m: VectorMock
        init(_ m: VectorMock) { self.m = m }
        func get(_ url: String, completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
            m.cfgRequests += 1
            m.respond(m.cfgScript, completion)
        }
        func post(_ url: String, body: String, headers: [String: String], completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
            m.requests.append((url, JSONValue.parse(body), m.now, body.utf8.count))
            var script = m.collect
            if var seq = m.collectSeq {
                script = seq.count > 1 ? seq.removeFirst() : seq[0]
                m.collectSeq = seq
            }
            m.respond(script, completion)
        }
    }

    final class MLifecycle: TCLifecycle {
        unowned let m: VectorMock
        init(_ m: VectorMock) { self.m = m }
        func bind(_ handlers: TCLifecycleHandlers) { m.handlers = handlers }
    }

    final class MDevice: TCDeviceInfo {
        unowned let m: VectorMock
        init(_ m: VectorMock) { self.m = m }
        var platform: String { m.platform }
        func read() -> TCDeviceSnapshot {
            m.deviceReads += 1
            return TCDeviceSnapshot(os: "Android", osVersion: "14", brand: "Google", model: "Pixel 8", deviceType: "phone", screenWidth: 1080, screenHeight: 2400, pixelRatio: 2.75, locale: "zh-CN", timezone: "Asia/Shanghai", hostVersion: "14")
        }
        func networkType(_ completion: @escaping (String?) -> Void) {
            m.deferred.append { completion("wifi") }
        }
        func deviceId() -> String? { m.nativeDeviceId }
    }

    final class MTimers: TCTimers {
        unowned let m: VectorMock
        init(_ m: VectorMock) { self.m = m }
        func now() -> Int64 { m.now }
        func setTimeout(_ ms: Int64, _ fn: @escaping () -> Void) -> Int {
            m.seq += 1
            m.timers[m.seq] = (m.now + max(0, ms), fn, 0)
            return m.seq
        }
        func clearTimeout(_ id: Int) { m.timers.removeValue(forKey: id) }
        func setInterval(_ ms: Int64, _ fn: @escaping () -> Void) -> Int {
            m.seq += 1
            m.timers[m.seq] = (m.now + max(1, ms), fn, max(1, ms))
            return m.seq
        }
        func clearInterval(_ id: Int) { m.timers.removeValue(forKey: id) }
        func random() -> Double { m.rng.next() }
    }

    final class MAutoTrack: TCAutoTrackHook {
        unowned let m: VectorMock
        init(_ m: VectorMock) { self.m = m }
        func enable(_ cb: @escaping (TCElement, TCPageInfo?) -> Void) { m.autoCb = cb }
        func disable() { m.autoCb = nil }
    }

    final class MCrash: TCCrashHook {
        unowned let m: VectorMock
        init(_ m: VectorMock) { self.m = m }
        func enable(_ cb: @escaping (TCCrashEvent) -> Void) { m.crashCb = cb }
        func disable() { m.crashCb = nil }
    }
}

final class Matcher {
    private var vars: [String: JSONValue] = [:]
    private static let uuidRe = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    private static let didRe = try! NSRegularExpression(pattern: "^(web_cookie|web_cookieless|mp_openid|mp_uuid|ios_idfv|android_id|harmony_odid|custom):[A-Za-z0-9_-]{8,64}$")

    static func test(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static func test(_ pattern: String, _ s: String) -> Bool {
        test(try! NSRegularExpression(pattern: pattern), s)
    }

    func match(_ expected: JSONValue, _ actual: JSONValue?, _ path: String, _ out: inout [String]) {
        if case .string(let s) = expected, s.hasPrefix("<"), s.hasSuffix(">") {
            token(String(s.dropFirst().dropLast()), actual, path, &out)
            return
        }
        switch expected {
        case .array(let e):
            guard let a = actual?.arrayValue else { out.append("\(path): expected array, got \(desc(actual))"); return }
            if e.count != a.count { out.append("\(path): expected \(e.count) items, got \(a.count)"); return }
            for (i, x) in e.enumerated() { match(x, a[i], "\(path)[\(i)]", &out) }
        case .object(let e):
            guard let a = actual?.objectValue else { out.append("\(path): expected object, got \(desc(actual))"); return }
            e.forEach { k, v in match(v, a[k], "\(path).\(k)", &out) }
        default:
            if actual != expected { out.append("\(path): expected \(expected.stringify()), got \(desc(actual))") }
        }
    }

    private func desc(_ v: JSONValue?) -> String { v?.stringify() ?? "undefined" }

    private func token(_ t: String, _ actual: JSONValue?, _ path: String, _ out: inout [String]) {
        func fail(_ why: String) { out.append("\(path): \(why) (got \(desc(actual)))") }
        let str = actual?.stringValue
        switch t {
        case "any": if actual == nil { fail("expected present") }
        case "absent": if actual != nil { fail("expected absent") }
        case "uuid": if !(str.map { Matcher.test(Matcher.uuidRe, $0) } ?? false) { fail("expected uuid v4") }
        case "ts", "num": if !(actual?.numberValue?.isFinite ?? false) { fail("expected number") }
        case "str": if (str ?? "").isEmpty { fail("expected non-empty string") }
        case "bool": if actual?.boolValue == nil { fail("expected boolean") }
        case "hex64": if !(str.map { Matcher.test("^[a-f0-9]{64}$", $0) } ?? false) { fail("expected sha256 hex") }
        case "did": if !(str.map { Matcher.test(Matcher.didRe, $0) } ?? false) { fail("expected device id") }
        case "sid": if !(str.map { Matcher.test("^[A-Za-z0-9]{8,32}$", $0) } ?? false) { fail("expected session id") }
        default:
            if t.hasPrefix("did:") {
                let prefix = String(t.dropFirst(4)) + ":"
                if !(str.map { Matcher.test(Matcher.didRe, $0) && $0.hasPrefix(prefix) } ?? false) { fail("expected device id with prefix \(prefix)") }
            } else if t.hasPrefix("re:") {
                if !(str.map { Matcher.test(String(t.dropFirst(3)), $0) } ?? false) { fail("expected /\(t.dropFirst(3))/") }
            } else if t.hasPrefix("$") {
                guard let actual else { fail("expected present (capture)"); return }
                if let prev = vars[t] {
                    if prev.stringify() != actual.stringify() { fail("expected same as \(t)=\(prev.stringify())") }
                } else {
                    vars[t] = actual
                }
            } else if t.hasPrefix("!$") {
                let name = String(t.dropFirst())
                guard let actual else { fail("expected present"); return }
                guard let prev = vars[name] else { fail("\(name) not captured yet"); return }
                if prev.stringify() == actual.stringify() { fail("expected different from \(name)") }
            } else if actual != .string("<\(t)>") {
                out.append("\(path): expected \"<\(t)>\", got \(desc(actual))")
            }
        }
    }
}

struct VectorResult {
    var failures: [String]
    var items: [JSONValue]
}

enum VectorRunner {
    static func run(_ v: JSONObject) throws -> VectorResult {
        let m = VectorMock(v)
        var errors: [String] = []
        var sessions: [JSONValue] = []
        var consents: [JSONValue] = []
        var out: [String] = []
        let mt = Matcher()

        func boot() -> TapCubCore {
            let sdk = TapCubCore(m.adapters())
            sdk.onError { code, _ in errors.append(code) }
            sdk.onSessionStart { sid, reason in sessions.append(.object(["sid": .string(sid), "reason": .string(reason)])) }
            sdk.onConsentChange { c in consents.append(.number(Double(c))) }
            if v["config"] != .null {
                var c: JSONObject = ["siteKey": .string("k_vector_site"), "endpoint": .string("https://c.test"), "appId": .string("wxvector")]
                if let extra = v["config"]?.objectValue { c.merge(extra) }
                sdk.preInit(TapCubConfig(json: c))
            }
            return sdk
        }
        var sdk = boot()

        for step in v["steps"]?.arrayValue ?? [] {
            guard let s = step.objectValue else { continue }
            if let call = s["call"]?.stringValue {
                let value = try dispatch(sdk, call, s["args"]?.arrayValue ?? [], m)
                if let e = s["expect"] { mt.match(e, value, "call \(call)() return", &out) }
            } else if let ms = s["advance"]?.numberValue {
                m.advance(Int64(ms))
            } else if s["restart"] != nil {
                m.timers.removeAll()
                sdk = boot()
            } else if let tap = s["tap"]?.objectValue {
                let page = s["page"]?.stringValue.map { TCPageInfo(path: $0) }
                m.autoCb?(TCElement(type: tap["type"]?.stringValue, id: tap["id"]?.stringValue, content: tap["content"]?.stringValue, path: tap["path"]?.stringValue), page)
            } else if let c = s["crash"]?.objectValue {
                m.crashCb?(TCCrashEvent(kind: c["kind"]?.stringValue ?? "crash", type: c["type"]?.stringValue, message: c["message"]?.stringValue, stack: c["stack"]?.stringValue, fatal: c["fatal"]?.boolValue, durationMs: c["durationMs"]?.numberValue.map { Int($0) }, foreground: c["foreground"]?.boolValue, ts: c["ts"]?.numberValue.map { Int64($0) }))
            } else if let kind = s["lifecycle"]?.stringValue {
                guard let h = m.handlers else { throw VectorError(description: "lifecycle not bound (preInit not called)") }
                let info = launchInfo(s["info"]?.objectValue)
                switch kind {
                case "launch": h.onLaunch(info)
                case "show": h.onShow(info)
                case "hide": h.onHide()
                default: throw VectorError(description: "unknown lifecycle \(kind)")
                }
            } else if let pg = s["page"]?.stringValue {
                guard let h = m.handlers else { throw VectorError(description: "lifecycle not bound") }
                let info = TCPageInfo(path: s["path"]?.stringValue ?? "", query: strMap(s["query"]?.objectValue), title: s["title"]?.stringValue)
                if pg == "show" { h.onPageShow(info) } else { h.onPageHide(info) }
            } else if s["share"] != nil {
                m.handlers?.onShare(TCPageInfo(path: s["path"]?.stringValue ?? "pages/index/index"), s["share"]?.stringValue ?? "")
            } else if s["favorite"] != nil {
                // no-op in the App core
            } else if let net = s["net"]?.objectValue {
                if let c = net["cfg"] { m.cfgScript = c }
                if let c = net["collect"] {
                    m.collect = c
                    m.collectSeq = c.arrayValue
                }
            } else if let f = s["storageFail"] {
                m.storageFail = truthyValue(f)
            } else {
                throw VectorError(description: "unknown step \(step.stringify())")
            }
            m.drain()
        }

        let e = v["expect"]?.objectValue ?? JSONObject()
        let items: [JSONValue] = m.requests.flatMap { $0.body?["items"]?.arrayValue ?? [] }
        if let x = e["items"] { mt.match(x, .array(items), "items", &out) }
        if let x = e["itemNames"] {
            let names: [JSONValue] = items.map { i in
                if i["t"]?.stringValue == "id" { return .string("id:\(i["op"]?.stringValue ?? "")") }
                return i["n"] ?? .null
            }
            mt.match(x, .array(names), "itemNames", &out)
        }
        if let x = e["requests"] {
            let reqs: [JSONValue] = m.requests.map { r in
                var o = JSONObject()
                o["url"] = .string(r.url)
                o["sent"] = r.body?["sent"]
                o["items"] = r.body?["items"]
                o["count"] = r.body?["items"]?.arrayValue.map { .number(Double($0.count)) }
                o["bytes"] = .number(Double(r.bytes))
                o["at"] = .number(Double(r.at - m.start))
                return .object(o)
            }
            mt.match(x, .array(reqs), "requests", &out)
        }
        if let x = e["requestCount"] { mt.match(x, .number(Double(m.requests.count)), "requestCount", &out) }
        if let x = e["cfgRequests"] { mt.match(x, .number(Double(m.cfgRequests)), "cfgRequests", &out) }
        if let x = e["deviceReads"] { mt.match(x, .number(Double(m.deviceReads)), "deviceReads", &out) }
        if let x = e["state"] { mt.match(x, .object(sdk.getState().toJSON()), "state", &out) }
        if let x = e["errors"] { mt.match(x, .array(errors.map { .string($0) }), "errors", &out) }
        if let x = e["errorsInclude"]?.arrayValue {
            for c in x where !errors.contains(c.stringValue ?? "") {
                out.append("errors: expected to include \(c.stringify()), got \(errors)")
            }
        }
        if let x = e["sessions"] { mt.match(x, .array(sessions), "sessions", &out) }
        if let x = e["consents"] { mt.match(x, .array(consents), "consents", &out) }
        let dump: JSONObject = {
            var o = JSONObject()
            for k in m.store.keys.sorted() { o[k] = .string(m.store[k]!) }
            return o
        }()
        if let x = e["storage"] { mt.match(x, .object(dump), "storage", &out) }
        if let x = e["storageKeys"] { mt.match(x, .array(dump.keys.map { .string($0) }), "storageKeys", &out) }
        return VectorResult(failures: out, items: items)
    }

    private static func truthyValue(_ v: JSONValue) -> Bool {
        switch v {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .null: return false
        default: return true
        }
    }

    private static func strMap(_ o: JSONObject?) -> [String: String]? {
        guard let o else { return nil }
        var d: [String: String] = [:]
        o.forEach { k, v in d[k] = v.stringValue ?? v.stringify() }
        return d
    }

    private static func launchInfo(_ o: JSONObject?) -> TCLaunchInfo {
        TCLaunchInfo(scene: o?["scene"], path: o?["path"]?.stringValue, query: strMap(o?["query"]?.objectValue) ?? [:])
    }

    private static func str(_ v: JSONValue?) -> String? {
        switch v {
        case .some(.string(let s)): return s
        case .some(.number(let n)): return JSONValue.formatNumber(n)
        default: return nil
        }
    }

    private static func obj(_ v: JSONValue?) -> JSONObject? { v?.objectValue }

    static func dispatch(_ sdk: TapCubCore, _ call: String, _ a: [JSONValue], _ m: VectorMock) throws -> JSONValue? {
        func arg(_ i: Int) -> JSONValue? { i < a.count ? a[i] : nil }
        switch call {
        case "init":
            sdk.initialize()
            m.drain()
        case "flush": sdk.flush()
        case "track": sdk.track(str(arg(0)) ?? "", props: obj(arg(1)))
        case "trackScreen": sdk.trackScreen(str(arg(0)) ?? "", props: obj(arg(1)))
        case "login": sdk.login(str(arg(0)) ?? "", props: obj(arg(1)), type: arg(2)?["type"]?.stringValue)
        case "logout": sdk.logout()
        case "bind": sdk.bind(obj(arg(0)) ?? JSONObject())
        case "setProps": sdk.setProps(obj(arg(0)) ?? JSONObject())
        case "setPropsOnce": sdk.setPropsOnce(obj(arg(0)) ?? JSONObject())
        case "unsetProps": sdk.unsetProps(arg(0)?.arrayValue?.compactMap { $0.stringValue } ?? [])
        case "setGroup": sdk.setGroup(str(arg(0)) ?? "", id: str(arg(1)), traits: obj(arg(2)))
        case "reset": sdk.reset()
        case "anonymize": sdk.anonymize()
        case "grantConsent":
            if let n = arg(0)?.numberValue { sdk.grantConsent(bits: Int(n)) } else { sdk.grantConsent(arg(0)?.arrayValue?.compactMap { $0.stringValue } ?? []) }
        case "revokeConsent": sdk.revokeConsent()
        case "getConsent": return .number(Double(sdk.getConsent()))
        case "optOut": sdk.optOut()
        case "optIn": sdk.optIn()
        case "setRestricted": sdk.setRestricted(arg(0)?.boolValue != false)
        case "setChildMode": sdk.setChildMode(arg(0)?.boolValue != false)
        case "setDataRegion": sdk.setDataRegion(str(arg(0)) ?? "")
        case "shouldPrompt": return .bool(sdk.shouldPrompt())
        case "stop": sdk.stop()
        case "start": sdk.start()
        case "registerSuperProps": sdk.registerSuperProps(obj(arg(0)) ?? JSONObject())
        case "unregisterSuperProp": sdk.unregisterSuperProp(str(arg(0)) ?? "")
        case "getState": return .object(sdk.getState().toJSON())
        case "getRemoteConfig": return .object(sdk.getRemoteConfig().toJSON())
        case "getDeviceId": return sdk.getDeviceId().map { .string($0) } ?? .null
        case "getSessionId": return sdk.getSessionId().map { .string($0) } ?? .null
        case "trackDeeplink": sdk.trackDeeplink(str(arg(0)) ?? "", referrer: str(arg(1)))
        case "trackPurchase": sdk.trackPurchase(obj(arg(0)) ?? JSONObject())
        case "withShareParams": return .string(sdk.withShareParams(str(arg(0)) ?? ""))
        case "requiredPrivacyApis": return .array([])
        default: throw VectorError(description: "unknown call \(call)")
        }
        return nil
    }
}
