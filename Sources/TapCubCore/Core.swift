import Foundation

// Line-by-line port of packages/app-sdk/src/core/sdk.ts. Method order and storage keys match the TS core;
// change the shared vectors and the TS core first, then this file. Not thread-safe: the `TapCub`
// facade confines every call to one serial queue.

public let TC_LIB_VERSION = "0.1.0"

func libName(_ pt: String) -> String {
    pt == "ios" ? "tapcub-ios" : pt == "harmony" ? "tapcub-harmony" : "tapcub-android"
}

private let HOLD_MAX = 200
private let IDENTITY_HOLD_MS: Int64 = 800
private let SESSION_COOLDOWN_MS: Int64 = 15000
private let SESSION_MAX_MS: Int64 = 86_400_000
private let CFG_CACHE_MS: Double = 86_400_000
private let MAX_BACKOFF_MS: Double = 300_000
private let FAILURES_BEFORE_SWITCH = 10

private enum K {
    static let cfg = "tc_cfg"
    static let did = "tc_did"
    static let consent = "tc_consent"
    static let rejectAt = "tc_consent_reject_at"
    static let optout = "tc_optout"
    static let child = "tc_child"
    static let login = "tc_login"
    static let group = "tc_group"
    static let superProps = "tc_sp"
    static let first = "tc_first"
}

private let PRESET_EVENT_RE = TCRegex("^\\$((app_(install|start|end|click|update|crashed))|anr|ui_freeze|rage_tap|deeplink_launch|push_click|in_app_purchase|ad_impression|fps_sample|memory_sample|screen_view|screen_leave|os_update|user_engagement)$")
private let GROUP_TYPE_RE = TCRegex("^[a-z][a-z0-9_]{0,23}$")
private let CUSTOM_ID_RE = TCRegex("^[A-Za-z0-9_-]{8,64}$")
private let DIGITS_RE = TCRegex("\\d+")
private let DEEPLINK_SECRET_RE = TCRegex("([?&])(token|code|auth|password|pwd)=[^&]*", caseInsensitive: true)
private let LEADING_SLASHES_RE = TCRegex("^/+")
private let TRAILING_SLASHES_RE = TCRegex("/+$")

public typealias TCConsentListener = (Int) -> Void
/// reason: init | timeout | login | max_age | logout
public typealias TCSessionListener = (String, String) -> Void
public typealias TCErrorListener = (String, String) -> Void

private struct HoldItem {
    var ts: Int64
    var mid: String
    var build: () -> JSONObject
}

private struct LoginState {
    var id: String
    var type: String
    var json: String { JSONObject(dictionaryLiteral: ("id", .string(id)), ("type", .string(type))).stringify() }
}

public final class TapCubCore {
    private var cfg = TapCubConfig(siteKey: "")
    private var policy = TCReportPolicy()
    private var qLimits = TCQueueLimits()
    private var endpoints: [String] = []
    private var endpointIdx = 0
    private let platform: String

    private var preInited = false
    private var initialized = false
    private var ready = false
    private var stopped = false
    private var server = TCServerCfg.conservative
    private var rc = TCRemoteConfig()
    private var device = TCDeviceSnapshot()
    private var deviceRead = false
    private var networkType = "unknown"

    private var did: String?
    /// `ver == nil` means the key is absent (TS `undefined`).
    private var consent: (c: Int, ver: JSONValue?)?
    private var optout = false
    private var child = false
    private var auth: LoginState?
    private var group: String?
    private var superProps = JSONObject()
    private var firstTs: Int64 = 0
    private var firstLaunch = false

    private var sid: String?
    private var sessionStart: Int64 = 0
    private var sessionCount = 0
    private var hideAt: Int64 = 0
    private var fgSince: Int64 = 0
    private var fgAccum: Int64 = 0
    private var foreground = false

    private var launch: TCLaunchInfo?
    private var launchPending = false
    private var pageViewPending = false
    private var pendingConsentReceipt = false
    private var latestScene: JSONValue?
    private var page: TCPageInfo?
    private var pageShownAt: Int64 = 0
    private var pageAccum: Int64 = 0
    private var previousScreen: String?
    private var shareDepth = 0
    private var shareFrom: String?

    private var hold: [HoldItem] = []
    private var pending: [() -> Void] = []
    private var identityHold = false
    private var identityHoldTimer: Int?
    private var queue: PersistentQueue
    private var sending = false
    private var failures = 0
    private var attempt = 0
    private var retryTimer: Int?
    private var intervalTimer: Int?
    private var sampled = true
    private var enabled = true
    private var outdated = false

    private var consentListeners: [TCConsentListener] = []
    private var sessionListeners: [TCSessionListener] = []
    private var errorListeners: [TCErrorListener] = []
    public private(set) var errors: [(code: String, message: String)] = []

    private let A: TCAdapters

    public init(_ adapters: TCAdapters) {
        A = adapters
        platform = adapters.device.platform
        let timers = adapters.timers
        queue = PersistentQueue(storage: adapters.storage, limits: TCQueueLimits(), now: { timers.now() }, onError: { _, _ in })
        queue = makeQueue()
    }

    private func makeQueue() -> PersistentQueue {
        let timers = A.timers
        return PersistentQueue(storage: A.storage, limits: qLimits, now: { timers.now() }, onError: { [weak self] c, m in self?.fail(c, m) })
    }

    private func lib() -> String { "\(libName(platform))/\(TC_LIB_VERSION)" }

    // MARK: - init

    /// Callable before consent: stores config and binds lifecycle only (no collection, no device reads, no network).
    @discardableResult
    public func preInit(_ config: TapCubConfig) -> Self {
        if preInited { return self }
        preInited = true
        cfg = config
        var p = TCReportPolicy()
        if let rp = config.reportPolicy {
            if let v = rp.onLaunch { p.onLaunch = v }
            if let v = rp.onBackground { p.onBackground = v }
            if let v = rp.intervalSec { p.intervalSec = v }
            if let v = rp.threshold { p.threshold = v }
        }
        policy = p
        if config.autoTrack == nil { cfg.autoTrack = true }
        var q = TCQueueLimits()
        if let ql = config.queue {
            if let v = ql.maxEvents { q.maxEvents = v }
            if let v = ql.maxDays { q.maxDays = v }
            if let v = ql.maxBatch { q.maxBatch = v }
            if let v = ql.maxBytes { q.maxBytes = v }
            if let v = ql.maxStorageBytes { q.maxStorageBytes = v }
        }
        qLimits = q
        queue = makeQueue()
        let single = config.endpoint.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        let list = (config.endpoints?.isEmpty == false ? config.endpoints! : single)
            .map { TRAILING_SLASHES_RE.replace($0, with: "") }
        endpoints = list.isEmpty ? ["https://api.pathclue.com"] : list
        A.lifecycle.bind(TCLifecycleHandlers(
            onLaunch: { [weak self] i in self?.handleLaunch(i) },
            onShow: { [weak self] i in self?.handleShow(i) },
            onHide: { [weak self] in self?.handleHide() },
            onPageShow: { [weak self] p in self?.handlePageShow(p) },
            onPageHide: { [weak self] p in self?.handlePageHide(p) },
            onShare: { [weak self] p, m in self?.handleShare(p, m) }
        ))
        A.crash?.enable { [weak self] ev in self?.reportException(ev) }
        return self
    }

    /// After consent (or when the site needs none): fetch cfg → consent gate → device info / device id / session / flush.
    public func initialize(_ config: TapCubConfig? = nil, completion: (() -> Void)? = nil) {
        if let config, !preInited { preInit(config) }
        if initialized { completion?(); return }
        if cfg.siteKey.isEmpty {
            fail("internal", "siteKey required")
            completion?()
            return
        }
        initialized = true
        loadState()
        if optout {
            ready = true
            hold = []
            completion?()
            return
        }
        fetchCfg { [weak self] in
            guard let self else { return }
            self.ready = true
            if self.pendingConsentReceipt {
                self.pendingConsentReceipt = false
                self.idOp("consent", ["c": .number(Double(self.consentBits()))], receipt: true)
            }
            self.applyGate()
            let calls = self.pending
            self.pending = []
            for c in calls { c() }
            completion?()
        }
    }

    private func loadState() {
        if let c = safeParseObject(get(K.consent)), let bits = c["c"]?.numberValue {
            consent = (Int(bits), c["ver"])
        } else {
            consent = nil
        }
        optout = get(K.optout) == "1"
        child = get(K.child) == "1"
        if let l = safeParseObject(get(K.login)), let id = l["id"]?.stringValue {
            auth = LoginState(id: id, type: l["type"]?.stringValue ?? "login")
        } else {
            auth = nil
        }
        group = get(K.group).flatMap { $0.isEmpty ? nil : $0 }
        superProps = safeParseObject(get(K.superProps)) ?? JSONObject()
        let first = Double(get(K.first) ?? "") ?? 0
        if first > 0 {
            firstTs = Int64(first)
        } else {
            firstTs = now()
            firstLaunch = true
            set(K.first, String(firstTs))
        }
        if let d = get(K.did), DEVICE_ID_RE.test(d) { did = d }
    }

    private func fetchCfg(_ done: @escaping () -> Void) {
        let cached = safeParseObject(get(K.cfg))
        let url = "\(endpoint())/api/v1/pulse/cfg?s=\(encodeURIComponent(cfg.siteKey))&pt=\(platform)"
        A.transport.get(url) { [weak self] result in
            guard let self else { return }
            var fetched: JSONValue?
            switch result {
            case .success(let res):
                if res.status == 200, let body = res.body, !body.isEmpty {
                    if let j = JSONValue.parse(body), j.objectValue != nil, j["t"]?.numberValue != nil { fetched = j }
                } else if res.status == 404 {
                    self.fail("cfg_failed", "site not found or paused")
                }
            case .failure(let e):
                self.fail("cfg_failed", "Error: \(e.localizedDescription)")
            }
            if let fetched {
                self.server = TCServerCfg(raw: fetched)
                self.set(K.cfg, JSONObject(dictionaryLiteral: ("cfg", fetched), ("at", .number(Double(self.now()))))
                    .stringify())
            } else if let cached, let ccfg = cached["cfg"], ccfg.objectValue != nil,
                      Double(self.now()) - (cached["at"]?.numberValue ?? .nan) < max(CFG_CACHE_MS, (ccfg["rc"]?["ttl"]?.numberValue ?? 0) * 1000) {
                self.server = TCServerCfg(raw: ccfg)
            } else {
                self.server = .conservative
                self.fail("cfg_failed", "no cfg; conservative defaults (t=2)")
            }
            self.rc = normalizeRc(self.server.rc)
            if let mv = self.rc.minVersion, compareSemver(TC_LIB_VERSION, mv) < 0 {
                self.outdated = true
                self.fail("sdk_outdated", "sdk \(TC_LIB_VERSION) < minVersion \(mv)")
            }
            done()
        }
    }

    // MARK: - consent gate

    private func requireConsent() -> Bool {
        cfg.requireConsent == true || truthy(server.cs?["req"]) || rc.requireConsent || cnMode()
    }
    private func cnMode() -> Bool {
        cfg.region == "cn" || server.cn || truthy(server.cs?["cn"])
    }
    private func consentBits() -> Int { consent?.c ?? 0 }
    private func granted() -> Bool { !requireConsent() || (consentBits() & 1) != 0 }
    private func dropMode() -> Bool { server.cs?["pre"]?.stringValue == "drop" }
    private func canDid() -> Bool { !child && server.t >= 3 && granted() }
    private func isOpen() -> Bool { ready && granted() && !optout && !stopped }
    private func canSend() -> Bool { isOpen() && enabled && !outdated }

    private func applyGate() {
        if optout { return }
        if !granted() {
            if dropMode() { hold = [] }
            return
        }
        ensureDid()
        enabled = rc.enabled && !(did.map { rc.deviceBlacklist.contains($0) } ?? false)
        if !deviceRead { readDevice() }
        if !queue.loaded { queue.load() }
        if sid == nil { startSession("init") }
        sampled = rc.sample >= 100 || Int(fnv1a(did ?? sid ?? "") % 100) < rc.sample
        if launchPending { emitLaunch() } else if pageViewPending, let page { emitPageView(page) }
        let holdIdentity = (cfg.holdUntilIdentified == true || server.h) && auth == nil
        if holdIdentity {
            identityHold = true
            identityHoldTimer = A.timers.setTimeout(IDENTITY_HOLD_MS) { [weak self] in self?.releaseIdentityHold() }
        } else {
            releaseHold()
        }
        startInterval()
        applyAutoTrack()
        if policy.onLaunch { flush() }
    }

    private var autoTrackOn = false
    private func applyAutoTrack() {
        guard let hook = A.autoTrack else { return }
        let want = cfg.autoTrack == true && rc.autotrack
        if want == autoTrackOn { return }
        autoTrackOn = want
        if !want {
            hook.disable()
            return
        }
        hook.enable { [weak self] el, page in
            guard let self else { return }
            let bl = self.rc.elementBlacklist
            if !bl.isEmpty && ((el.id.map { bl.contains($0) } ?? false) || (el.path.map { bl.contains($0) } ?? false)) { return }
            var p = JSONObject()
            p["$element_type"] = el.type.map { .string($0) } ?? .null
            p["$element_id"] = el.id.map { .string($0) } ?? .null
            p["$element_path"] = el.path.map { .string($0) } ?? .null
            p["$screen_name"] = (page?.path ?? self.page?.path).map { .string($0) } ?? .null
            if self.rc.textCapture, let c = el.content, !c.isEmpty { p["$element_content"] = .string(String(sha256(c).prefix(16))) }
            self.trackInternal("$app_click", p, page)
        }
    }

    private func releaseIdentityHold() {
        if !identityHold { return }
        identityHold = false
        if let t = identityHoldTimer { A.timers.clearTimeout(t) }
        identityHoldTimer = nil
        releaseHold()
        flush()
    }

    private func releaseHold() {
        if !isOpen() || identityHold { return }
        let items = hold
        hold = []
        for h in items {
            if !sampled { continue }
            var p = h.build()
            if let n = p["n"]?.stringValue, rc.blacklist.contains(n) { continue }
            p["ts"] = .number(Double(h.ts))
            p["mid"] = .string(h.mid)
            queue.push(p)
        }
        maybeFlushByThreshold()
    }

    private func readDevice() {
        deviceRead = true
        device = A.device.read()
        A.device.networkType { [weak self] t in
            self?.networkType = (t?.isEmpty == false ? t! : "unknown")
        }
    }

    private func ensureDid() {
        if !canDid() { return }
        if did == nil {
            if let custom = cfg.deviceId, CUSTOM_ID_RE.test(custom) {
                did = "custom:\(custom)"
            } else if let custom = cfg.deviceId, DEVICE_ID_RE.test(custom) {
                did = custom
            } else if let native = A.device.deviceId(), DEVICE_ID_RE.test(native) {
                did = native
            } else {
                let prefix = platform == "ios" ? "ios_idfv" : platform == "harmony" ? "harmony_odid" : "android_id"
                let tsHex = (String(now(), radix: 16) + "000000000000").prefix(12)
                did = "\(prefix):\(tsHex)\(randomHex(A.timers.random, 10))"
            }
        }
        if let did { set(K.did, did) }
    }
    private func dropDid() {
        did = nil
        remove(K.did)
    }

    // MARK: - session

    private func startSession(_ reason: String) {
        let s = randomHex(A.timers.random, 16)
        sid = s
        sessionStart = now()
        sessionCount += 1
        fgAccum = 0
        if foreground { fgSince = sessionStart }
        for f in sessionListeners { f(s, reason) }
    }
    private func sessionExpired() -> Bool {
        if sid == nil { return true }
        let n = now()
        if n - sessionStart > SESSION_MAX_MS { return true }
        if hideAt == 0 { return false }
        let timeout = Int64(cfg.sessionTimeoutSec ?? 30) * 1000
        return n - hideAt >= timeout + SESSION_COOLDOWN_MS
    }
    private func foregroundSeconds() -> Int64 {
        var ms = fgAccum
        if foreground && fgSince != 0 { ms += now() - fgSince }
        return max(0, Int64(jsRound(Double(ms) / 1000)))
    }

    // MARK: - lifecycle

    private func handleLaunch(_ info: TCLaunchInfo) {
        launch = info
        latestScene = info.scene
        if let sd = info.query["tc_sd"], !sd.isEmpty {
            shareFrom = sd.jsSlice(64)
            let parsed = Int(info.query["tc_sdp"] ?? "1") ?? 0
            shareDepth = min(99, parsed == 0 ? 1 : parsed)
        }
        launchPending = true
        if isOpen() { emitLaunch() }
    }
    private func emitLaunch() {
        if !launchPending { return }
        launchPending = false
        replayPendingAppEnd()
        foreground = true
        fgSince = now()
        if firstLaunch { trackInternal("$app_install", ["$install_time": .number(Double(firstTs))]) }
        let dur = launchDurationMs()
        trackInternal("$app_start", ["$start_type": .string("cold"), "$resume_from_background": .bool(false), "$duration_ms": .number(Double(dur))])
        if pageViewPending, let page { emitPageView(page) }
    }
    private func launchDurationMs() -> Int64 {
        guard let raw = launch?.query["duration_ms"], let v = Double(raw), v.isFinite, v > 0 else { return 0 }
        return Int64(jsRound(v))
    }
    private func replayPendingAppEnd() {
        guard let raw = get("tc_end_pending") else { return }
        remove("tc_end_pending")
        let sec = Double(raw) ?? 0
        if sec > 0 { trackInternal("$app_end", ["$event_duration": .number(sec)], nil, hideAt != 0 ? hideAt : now()) }
    }
    private func handleShow(_ info: TCLaunchInfo) {
        if let s = info.scene { latestScene = s }
        if launchPending { return }
        if foreground { return }
        foreground = true
        fgSince = now()
        if page != nil { pageShownAt = now() }
        if !isOpen() { return }
        if sessionExpired() {
            emitAppEnd()
            startSession(now() - sessionStart > SESSION_MAX_MS ? "max_age" : "timeout")
            hideAt = 0
            trackInternal("$app_start", ["$start_type": .string("hot"), "$resume_from_background": .bool(true), "$duration_ms": .number(0)])
        }
    }
    private func handleHide() {
        if !foreground { return }
        foreground = false
        let n = now()
        hideAt = n
        if fgSince != 0 { fgAccum += n - fgSince }
        fgSince = 0
        if page != nil && pageShownAt != 0 {
            pageAccum += n - pageShownAt
            pageShownAt = 0
        }
        set("tc_end_pending", String(Int64(jsRound(Double(fgAccum) / 1000))))
        if !isOpen() { return }
        if policy.onBackground { flush() }
    }
    private func emitAppEnd() {
        let sec = foregroundSeconds()
        remove("tc_end_pending")
        if sec >= 0 { trackInternal("$app_end", ["$event_duration": .number(Double(sec))]) }
        fgAccum = 0
    }
    private func handlePageShow(_ p: TCPageInfo) {
        if let cur = page, cur.path != p.path { previousScreen = cur.path }
        page = p
        pageShownAt = now()
        pageAccum = 0
        if cfg.autoTrackScreens == false { return }
        if stopped || optout { return }
        if !isOpen() || launchPending {
            pageViewPending = true
            return
        }
        emitPageView(p)
    }
    private func emitPageView(_ p: TCPageInfo) {
        pageViewPending = false
        trackInternal("$screen_view", screenProps(p, previousScreen), p)
    }
    private func screenProps(_ p: TCPageInfo, _ prev: String?) -> JSONObject {
        var o = JSONObject()
        o["$path"] = .string(p.path)
        o["$screen_name"] = .string(p.path)
        if let q = p.query, !q.isEmpty {
            var qo = JSONObject()
            for k in q.keys.sorted() { qo[k] = .string(q[k]!) }
            o["$query"] = .string(qo.stringify())
        } else {
            o["$query"] = .null
        }
        o["$title"] = p.title.map { .string($0) } ?? .null
        o["$previous_screen"] = prev.map { .string($0) } ?? .null
        return o
    }
    private func handlePageHide(_ p: TCPageInfo) {
        var ms = pageAccum
        if pageShownAt != 0 { ms += now() - pageShownAt }
        pageShownAt = 0
        pageAccum = 0
        if cfg.autoTrackScreens == false { return }
        trackInternal("$screen_leave", ["$path": .string(p.path), "$screen_name": .string(p.path), "$duration": .number(jsRound(Double(ms) / 1000))], p)
    }
    private func handleShare(_ p: TCPageInfo, _ method: String) {
        trackInternal("$deeplink_launch", ["$deeplink_url": .string(p.path), "$referrer_app": method.isEmpty ? .null : .string(method)], p)
    }

    // MARK: - event building

    private func now() -> Int64 { A.timers.now() }
    private func pageUrl(_ p: TCPageInfo?) -> String {
        let host = ((cfg.appId?.isEmpty == false) ? cfg.appId! : platform).lowercased()
        let path = (p ?? page).map { LEADING_SLASHES_RE.replace($0.path, with: "") } ?? ""
        return "https://\(host)/\(path)".jsSlice(TCLimits.url)
    }
    private func presetProps() -> JSONObject {
        let d = device
        var out = JSONObject()
        out["$lib"] = .string(libName(platform))
        out["$lib_version"] = .string(TC_LIB_VERSION)
        out["$app_state"] = .string(foreground ? "foreground" : "background")
        if let v = cfg.appId, !v.isEmpty { out["$app_id"] = .string(v) }
        if let v = cfg.appVersion, !v.isEmpty { out["$app_version"] = .string(v) }
        if let v = d.os, !v.isEmpty { out["$os"] = .string(v) }
        if let v = d.osVersion, !v.isEmpty { out["$os_version"] = .string(v) }
        if let v = d.brand, !v.isEmpty { out["$device_brand"] = .string(v) }
        if let v = d.model, !v.isEmpty { out["$device_model"] = .string(v) }
        out["$device_type"] = .string(d.deviceType?.isEmpty == false ? d.deviceType! : "phone")
        if let v = d.screenWidth, v != 0 { out["$screen_width"] = .number(Double(v)) }
        if let v = d.screenHeight, v != 0 { out["$screen_height"] = .number(Double(v)) }
        if let v = d.hostVersion, !v.isEmpty { out["$host_version"] = .string(v) }
        out["$network_type"] = .string(networkType)
        if let s = launch?.scene { out["$scene"] = s }
        if let s = latestScene { out["$latest_scene"] = s }
        if let sf = shareFrom, !sf.isEmpty {
            out["$share_distinct_id"] = .string(sf)
            out["$share_depth"] = .number(Double(shareDepth))
        }
        out["$is_first_day"] = .bool(now() - firstTs < 86_400_000)
        out["$is_first_time"] = .bool(firstLaunch)
        return out
    }
    private func base(_ t: String, _ p: TCPageInfo? = nil) -> JSONObject {
        var o = JSONObject()
        o["v"] = .number(2)
        o["s"] = .string(cfg.siteKey)
        o["t"] = .string(t)
        o["u"] = .string(pageUrl(p))
        o["pt"] = .string(platform)
        o["lib"] = .string(lib())
        o["ts"] = .number(Double(now()))
        o["mid"] = .string(uuidV4(A.timers.random))
        if let sid { o["sid"] = .string(sid) }
        if let did { o["did"] = .string(did) }
        if let consent { o["c"] = .number(Double(consent.c)) }
        if child { o["cm"] = .number(1) }
        if let group { o["g"] = .string(group) }
        let d = device
        if let w = d.screenWidth, let h = d.screenHeight, w != 0, h != 0 { o["sc"] = .string("\(w)x\(h)") }
        if let l = d.locale, !l.isEmpty { o["l"] = .string(l.jsSlice(20)) }
        if let tz = d.timezone, !tz.isEmpty { o["tz"] = .string(tz.jsSlice(50)) }
        return o
    }
    private func buildEvent(_ name: String, _ props: JSONObject?, _ p: TCPageInfo?, _ extra: JSONObject?) -> JSONObject {
        var o = base("ev", p)
        o["n"] = .string(name)
        if let title = (p ?? page)?.title, !title.isEmpty { o["ti"] = .string(title.jsSlice(TCLimits.title)) }
        var merged = presetProps()
        merged.merge(superProps)
        if let props { merged.merge(props) }
        if let np = normProps(merged) { o["p"] = .object(np) }
        if let extra { o.merge(extra) }
        return o
    }

    // MARK: - enqueue / hold

    private func holdOrDrop(_ build: @escaping () -> JSONObject, _ ts: Int64? = nil) {
        if optout || stopped { return }
        if ready && dropMode() && !granted() { return }
        if hold.count >= HOLD_MAX {
            hold.removeFirst()
            fail("hold_overflow", "pre-consent hold full, dropped oldest")
        }
        hold.append(HoldItem(ts: ts ?? now(), mid: uuidV4(A.timers.random), build: build))
    }
    private func enqueue(_ build: @escaping () -> JSONObject, _ ts: Int64? = nil) {
        if optout || stopped { return }
        if !isOpen() || identityHold {
            holdOrDrop(build, ts)
            return
        }
        if !sampled { return }
        var p = build()
        if let ts, ts != 0 { p["ts"] = .number(Double(ts)) }
        queue.push(p)
        maybeFlushByThreshold()
    }
    private func maybeFlushByThreshold() {
        let th = rc.threshold != TCRemoteConfig().threshold ? rc.threshold : policy.threshold
        if th > 0 && queue.length >= th { flush() }
    }
    private func trackInternal(_ name: String, _ props: JSONObject?, _ p: TCPageInfo? = nil, _ ts: Int64? = nil, _ extra: JSONObject? = nil) {
        if rc.blacklist.contains(name) { return }
        enqueue({ [unowned self] in self.buildEvent(name, props, p, extra) }, ts)
    }

    // MARK: - sending

    private func endpoint() -> String { endpoints.isEmpty ? "https://api.pathclue.com" : endpoints[endpointIdx % endpoints.count] }
    private func startInterval() {
        if intervalTimer != nil { return }
        let sec = rc.interval != TCRemoteConfig().interval ? rc.interval : policy.intervalSec
        if sec > 0 {
            intervalTimer = A.timers.setInterval(Int64(sec) * 1000) { [weak self] in
                guard let self else { return }
                if self.retryTimer != nil || self.sending { return }
                self.flush()
            }
        }
    }
    private func stopTimers() {
        if let t = intervalTimer { A.timers.clearInterval(t) }
        intervalTimer = nil
        if let t = retryTimer { A.timers.clearTimeout(t) }
        retryTimer = nil
    }

    public func flush() {
        if sending || !canSend() { return }
        let batch = queue.peek()
        if batch.isEmpty { return }
        sending = true
        var req = JSONObject()
        req["sent"] = .number(Double(now()))
        req["items"] = .array(batch.map { .object($0) })
        let url = "\(endpoint())/api/v1/pulse"
        log("debug", "POST \(url) ×\(batch.count)")
        A.transport.post(url, body: req.stringify(), headers: ["Content-Type": "text/plain", "X-Tc-Lib": lib()]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res): self.onSent(res.status, batch)
            case .failure(let e):
                self.log("debug", "network error: \(e)")
                self.onSent(0, batch)
            }
        }
    }
    private func sendDirect(_ p: JSONObject) {
        var req = JSONObject()
        req["sent"] = .number(Double(now()))
        req["items"] = .array([.object(p)])
        A.transport.post("\(endpoint())/api/v1/pulse", body: req.stringify(), headers: ["Content-Type": "text/plain", "X-Tc-Lib": lib()]) { _ in }
    }
    private func onSent(_ status: Int, _ batch: [JSONObject]) {
        sending = false
        let count = batch.count
        if status >= 200 && status < 300 {
            queue.ack(batch)
            failures = 0
            attempt = 0
            if queue.length > 0 { flush() }
            return
        }
        if status == 429 || status >= 500 || status == 0 {
            failures += 1
            attempt += 1
            if failures >= FAILURES_BEFORE_SWITCH && endpoints.count > 1 {
                endpointIdx = (endpointIdx + 1) % endpoints.count
                failures = 0
                log("debug", "switch endpoint → \(endpoint())")
            }
            let delay = min(MAX_BACKOFF_MS, 1000 * pow(2, Double(min(attempt - 1, 20))))
            if let t = retryTimer { A.timers.clearTimeout(t) }
            retryTimer = A.timers.setTimeout(Int64(delay)) { [weak self] in
                self?.retryTimer = nil
                self?.flush()
            }
            return
        }
        queue.ack(batch)
        fail("send_failed", "HTTP \(status), batch of \(count) dropped")
        if queue.length > 0 { flush() }
    }

    // MARK: - public API: collection

    public func track(_ name: String, props: JSONObject? = nil) {
        if optout || stopped { return }
        var n = name.jsTrimmed
        if n.isEmpty { return }
        if n.jsLength > TCLimits.name { n = n.jsSlice(TCLimits.name) }
        if n.hasPrefix("$") && !PRESET_EVENT_RE.test(n) { n = String(n.dropFirst()) }
        if !initialized {
            let ts = now()
            pending.append { [unowned self] in self.trackInternal(n, props, nil, ts) }
            return
        }
        trackInternal(n, props)
    }
    public func trackScreen(_ name: String, props: JSONObject? = nil) {
        let path = name.jsTrimmed.jsSlice(200)
        if path.isEmpty { return }
        let pg = TCPageInfo(path: path, title: props?["$title"]?.stringValue)
        let prev = page?.path
        page = pg
        pageShownAt = now()
        var p = screenProps(pg, prev)
        if let props { p.merge(props) }
        trackInternal("$screen_view", p, pg)
    }

    // MARK: - public API: identity

    private func identityAllowed() -> Bool {
        if !ready { return true }
        if server.t < 3 {
            fail("identity_blocked_by_tier", "tier < 3")
            return false
        }
        if !server.i {
            log("debug", "identity ops ignored: site is anonymous mode")
            return false
        }
        return true
    }
    private func idOp(_ op: String, _ extra: JSONObject? = nil, receipt: Bool = false) {
        let build: () -> JSONObject = { [unowned self] in
            var p = self.base("id")
            p["op"] = .string(op)
            if let extra { p.merge(extra) }
            return p
        }
        if receipt {
            sendDirect(build())
            return
        }
        if !isOpen() {
            holdOrDrop(build)
            return
        }
        queue.push(build())
        flush()
    }
    private func idsFromProps(_ props: JSONObject?) -> JSONValue? {
        guard let props else { return nil }
        var ids = JSONObject()
        if let e = props["$email"]?.stringValue, !e.isEmpty { ids["email"] = .string(sha256(normId("email", e))) }
        if let m = props["$phone"]?.stringValue, !m.isEmpty { ids["mobile"] = .string(sha256(normId("mobile", m))) }
        return ids.isEmpty ? nil : .object(ids)
    }
    private func hashedId(_ type: String, _ v: String) -> String {
        (type == "email" || type == "mobile") ? (HEX64.test(v) ? v.lowercased() : sha256(normId(type, v))) : v
    }

    /// type: login | email | mobile | unionid | openid | custom
    public func login(_ id: String, props: JSONObject? = nil, type: String? = nil) {
        if !initialized || !ready {
            pending.append { [unowned self] in self.login(id, props: props, type: type) }
            return
        }
        if optout { return }
        var v = id.jsTrimmed
        let t = (type?.isEmpty == false) ? type! : "login"
        if v.isEmpty || v.jsLength > LOGIN_ID_MAX || BLOCKED_ID_RE.test(v) {
            fail("invalid_login_id", "blocked or empty id for type \(t)")
            return
        }
        if !identityAllowed() { return }
        v = hashedId(t, v)
        let switching = auth != nil && (auth!.id != v || auth!.type != t)
        let same = auth != nil && !switching
        auth = LoginState(id: v, type: t)
        set(K.login, auth!.json)
        if switching {
            hideAt = 0
            fgAccum = 0
            if foreground { fgSince = now() }
            startSession("login")
        }
        ensureDid()
        if !same || props != nil {
            var extra = JSONObject()
            extra["id"] = .string(v)
            extra["idt"] = .string(t)
            extra["h"] = .number(1)
            if let np = normProps(props, TCLimits.profileKeys) { extra["props"] = .object(np) }
            if let ids = idsFromProps(props) { extra["ids"] = ids }
            extra["src"] = .string("sdk")
            idOp("login", extra)
        }
        releaseIdentityHold()
    }
    public func logout() {
        if !initialized || !ready {
            pending.append { [unowned self] in self.logout() }
            return
        }
        if auth == nil { return }
        auth = nil
        remove(K.login)
        hideAt = 0
        startSession("logout")
        if identityAllowed() { idOp("logout") }
    }
    public func bind(_ ids: JSONObject) {
        if !ready {
            pending.append { [unowned self] in self.bind(ids) }
            return
        }
        if !identityAllowed() { return }
        var out = JSONObject()
        ids.forEach { k, raw in
            guard let s0 = raw.stringValue ?? raw.numberValue.map({ JSONValue.formatNumber($0) }), !s0.isEmpty else { return }
            let s = s0.jsTrimmed
            if s.isEmpty || s.jsLength > LOGIN_ID_MAX || BLOCKED_ID_RE.test(s) { return }
            out[k] = .string(hashedId(k, s))
        }
        if !out.isEmpty { idOp("bind", ["ids": .object(out), "h": .number(1)]) }
    }
    public func setProps(_ props: JSONObject) { profileOp("set", props) }
    public func setPropsOnce(_ props: JSONObject) { profileOp("set_once", props) }
    public func unsetProps(_ keys: [String]) {
        if !ready {
            pending.append { [unowned self] in self.unsetProps(keys) }
            return
        }
        if !identityAllowed() { return }
        let list = Array(keys.filter { !$0.isEmpty && $0.jsLength <= TCLimits.propKey }.prefix(TCLimits.profileKeys))
        if !list.isEmpty { idOp("unset", ["unset": .array(list.map { .string($0) }), "h": .number(1)]) }
    }
    private func profileOp(_ op: String, _ props: JSONObject) {
        if !ready {
            pending.append { [unowned self] in self.profileOp(op, props) }
            return
        }
        if !identityAllowed() { return }
        guard let p = normProps(props, TCLimits.profileKeys), !p.isEmpty else { return }
        var extra = JSONObject()
        extra[op == "set" ? "props" : "once"] = .object(p)
        if let ids = idsFromProps(props) { extra["ids"] = ids }
        extra["h"] = .number(1)
        idOp(op, extra)
    }
    public func setGroup(_ type: String, id: String?, traits: JSONObject? = nil) {
        let t = type.lowercased()
        let v = (id ?? "").jsTrimmed
        if !GROUP_TYPE_RE.test(t) || v.jsLength > 80 { return }
        group = v.isEmpty ? nil : "\(t):\(v)"
        if let group { set(K.group, group) } else { remove(K.group) }
        func extra(_ g: String?) -> JSONObject {
            var e = JSONObject()
            e["g"] = g.map { .string($0) } ?? .null
            if let np = normProps(traits, TCLimits.profileKeys) { e["props"] = .object(np) }
            e["h"] = .number(1)
            return e
        }
        if !ready {
            if group != nil { pending.append { [unowned self] in self.idOp("group", extra(self.group)) } }
            return
        }
        if let g = group, identityAllowed() { idOp("group", extra(g)) }
    }
    public func reset() {
        if !ready {
            pending.append { [unowned self] in self.reset() }
            return
        }
        dropDid()
        auth = nil
        remove(K.login)
        hideAt = 0
        startSession("logout")
        ensureDid()
        if identityAllowed() { idOp("reset") }
    }
    public func anonymize() { reset() }

    // MARK: - public API: consent / compliance

    /// purposes: analytics | functional | marketing
    public func grantConsent(_ purposes: [String]) {
        var c = 0
        for p in purposes { c |= p == "analytics" ? 1 : p == "functional" ? 2 : p == "marketing" ? 4 : 0 }
        grantConsent(bits: c)
    }
    public func grantConsent(bits: Int) {
        let c = bits & 7
        let ver: JSONValue? = server.cs == nil ? .null : server.cs?["ver"]
        consent = (c, ver)
        var stored = JSONObject()
        stored["c"] = .number(Double(c))
        stored["ver"] = ver
        set(K.consent, stored.stringify())
        if c & 1 == 0 {
            set(K.rejectAt, String(now()))
            dropDid()
            queue.purge()
            if cnMode() { hold = [] }
        } else {
            remove(K.rejectAt)
        }
        if initialized && ready && !optout {
            idOp("consent", ["c": .number(Double(c))], receipt: true)
            if c & 1 != 0 { applyGate() } else { stopTimers() }
        } else if !optout {
            pendingConsentReceipt = true
        }
        for f in consentListeners { f(c) }
    }
    public func revokeConsent() { grantConsent(bits: 0) }
    public func getConsent() -> Int { consentBits() }
    public func optOut() {
        if optout { return }
        optout = true
        set(K.optout, "1")
        if initialized && ready { idOp("optout", ["c": .number(0)], receipt: true) }
        dropDid()
        queue.purge()
        hold = []
        stopTimers()
    }
    public func optIn() {
        if !optout { return }
        optout = false
        remove(K.optout)
        if initialized && ready {
            idOp("optin", ["c": .number(Double(consentBits()))], receipt: true)
            applyGate()
        }
    }
    public func setRestricted(_ on: Bool) {
        if on { optOut() } else { optIn() }
    }
    public func setChildMode(_ on: Bool) {
        child = on
        if child {
            set(K.child, "1")
            dropDid()
        } else {
            remove(K.child)
        }
    }
    /// eu | us | cn — only before `initialize`.
    public func setDataRegion(_ region: String) {
        if initialized {
            fail("internal", "setDataRegion must be called before init()")
            return
        }
        cfg.region = region
    }
    public func shouldPrompt() -> Bool {
        if let c = consent, c.c & 1 != 0 { return false }
        let r = Double(get(K.rejectAt) ?? "") ?? 0
        let rej = server.cs?["rej"]?.numberValue ?? 0
        let days = Double(cfg.rejectCooldownDays ?? 0) != 0 ? Double(cfg.rejectCooldownDays!) : (rej != 0 ? rej : 7)
        return r == 0 || Double(now()) - r > days * 86_400_000
    }
    public func stop() {
        stopped = true
        stopTimers()
    }
    public func start() {
        if !stopped { return }
        stopped = false
        if ready { applyGate() }
    }

    // MARK: - public API: properties / getters / listeners

    public func registerSuperProps(_ props: JSONObject) {
        let p = normProps(props) ?? JSONObject()
        p.forEach { k, v in if !k.hasPrefix("$") { superProps[k] = v } }
        set(K.superProps, superProps.stringify())
    }
    public func unregisterSuperProp(_ key: String) {
        superProps[key] = nil
        set(K.superProps, superProps.stringify())
    }
    public func withShareParams(_ path: String) -> String {
        let sd = did.map { String(fnv1a($0), radix: 36) } ?? sid.map { String($0.prefix(8)) } ?? ""
        if sd.isEmpty { return path }
        let sep = path.contains("?") ? "&" : "?"
        return "\(path)\(sep)tc_sd=\(sd)&tc_sdp=\(shareDepth + 1)"
    }
    public func getDeviceId() -> String? { did }
    public func getSessionId() -> String? { sid }
    public func getConfig() -> TapCubConfig { cfg }
    public func getRemoteConfig() -> TCRemoteConfig { rc }
    public func requiredPrivacyApis() -> [String] { [] }

    public func reportException(_ ev: TCCrashEvent) {
        if cfg.crashReport == false { return }
        let type = (ev.type?.isEmpty == false ? ev.type! : ev.kind).jsSlice(80)
        let msg = (ev.message ?? "").jsSlice(TCLimits.message)
        let st = (ev.stack ?? "").jsSlice(TCLimits.stack)
        let top = st.components(separatedBy: "\n").first { !$0.jsTrimmed.isEmpty } ?? type
        let group = String(sha256(type + DIGITS_RE.replace(top, with: "")).prefix(40))
        let name = ev.kind == "anr" ? "$anr" : ev.kind == "freeze" ? "$ui_freeze" : "$app_crashed"
        var p = JSONObject()
        p["$fatal"] = .bool(ev.fatal != false)
        p["$exception_type"] = .string(type)
        p["$exception_message"] = .string(msg)
        p["$group"] = .string(group)
        p["$foreground"] = .bool(ev.foreground != false)
        p["$duration_ms"] = ev.durationMs.map { .number(Double($0)) } ?? .null
        p["$stack_top"] = .string(top.jsSlice(200))
        trackInternal(name, p, nil, (ev.ts ?? 0) > 0 ? ev.ts : nil, st.isEmpty ? nil : ["st": .string(st)])
    }
    public func trackPurchase(_ info: JSONObject) { track("$in_app_purchase", props: info) }
    public func trackPushClick(_ payload: JSONObject) { track("$push_click", props: payload) }
    public func setAttribution(_ attrs: JSONObject) { registerSuperProps(attrs) }
    public func trackDeeplink(_ url: String, referrer: String? = nil) {
        let clean = DEEPLINK_SECRET_RE.replace(url, with: "$1$2=")
        trackInternal("$deeplink_launch", ["$deeplink_url": .string(clean.jsSlice(500)), "$referrer_app": referrer.map { .string($0) } ?? .null])
    }
    public func onConsentChange(_ cb: @escaping TCConsentListener) { consentListeners.append(cb) }
    public func onSessionStart(_ cb: @escaping TCSessionListener) { sessionListeners.append(cb) }
    public func onError(_ cb: @escaping TCErrorListener) { errorListeners.append(cb) }

    public func getState() -> TCState {
        TCState(
            initialized: initialized,
            deviceId: did,
            sessionId: sid,
            consent: consent?.c,
            optedOut: optout,
            loginId: auth?.id,
            loginType: auth?.type,
            queueLength: queue.length,
            holdLength: hold.count,
            enabled: enabled && !outdated,
            sampled: sampled,
            tier: server.t,
            endpoint: endpoint(),
            sessionCount: sessionCount
        )
    }

    // MARK: - helpers

    private func fail(_ code: String, _ message: String) {
        if errors.count < 100 { errors.append((code, message)) }
        log("error", "[\(code)] \(message)")
        for f in errorListeners { f(code, message) }
    }
    private func log(_ level: String, _ msg: String) {
        if level == "debug" && cfg.debug != true { return }
        A.log?(level, msg)
    }
    private func get(_ k: String) -> String? { A.storage.get(k) }
    private func set(_ k: String, _ v: String) {
        do {
            try A.storage.set(k, v)
        } catch {
            fail("storage_failed", "\(k): \(error)")
        }
    }
    private func remove(_ k: String) { A.storage.remove(k) }
}

/// JS `encodeURIComponent`.
func encodeURIComponent(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
