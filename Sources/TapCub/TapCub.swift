import Foundation
#if canImport(TapCubCore)
@_exported import TapCubCore
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Public entry point. Every call is confined to one serial worker queue and returns immediately;
/// getters wait for the queue. Listener callbacks are delivered on the main queue.
///
///     TapCub.preInit(TapCubConfig(siteKey: "s_xxx", appId: Bundle.main.bundleIdentifier))
///     TapCub.initialize()   // after consent, or right away when the site needs none
public enum TapCub {
    static let queue = DispatchQueue(label: TapCubBrand.workerQueue, qos: .utility)
    private static let onQueue = DispatchSpecificKey<Bool>()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var created = false
    nonisolated(unsafe) private static var core: TapCubCore?
    nonisolated(unsafe) private static var perfEnabled = false

    /// Native defaults: a larger on-disk queue than the mini-program 1 MB limit.
    static let nativeQueue = TCPartialQueue(maxEvents: 10000, maxDays: 7, maxStorageBytes: 8 * 1_048_576)

    // MARK: lifecycle

    /// Stores config and binds lifecycle only: no collection, no device reads, no network until `initialize`.
    /// Call from the main thread (e.g. `application(_:didFinishLaunchingWithOptions:)`).
    public static func preInit(_ config: TapCubConfig) {
        precondition(!config.siteKey.isEmpty, "siteKey required")
        lock.lock()
        defer { lock.unlock() }
        if created { return }
        created = true
        queue.setSpecific(key: onQueue, value: true)
        var cfg = config
        if cfg.queue == nil { cfg.queue = nativeQueue }
        if cfg.appId == nil { cfg.appId = Bundle.main.bundleIdentifier }
        if cfg.appVersion == nil { cfg.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
        if cfg.appBuild == nil { cfg.appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
        let storage = TCDeviceStorage()
        let debug = cfg.debug == true
        let adapters = TCAdapters(
            storage: storage,
            transport: TCURLSessionTransport(queue: queue),
            lifecycle: TCAppLifecycle(queue: queue, autoTrackScreens: cfg.autoTrackScreens != false),
            device: TCSystemDevice(queue: queue, storage: storage),
            timers: TCDispatchTimers(queue: queue),
            autoTrack: TCAutoTrack(queue: queue),
            crash: cfg.crashReport == false ? nil : TCCrashReporter(queue: queue),
            log: { level, msg in if debug { NSLog("%@ %@: %@", TapCubBrand.logTag, level, msg) } }
        )
        perfEnabled = cfg.perf == true
        queue.async {
            let c = TapCubCore(adapters)
            c.onSessionStart { _, _ in samplePerf() }
            c.preInit(cfg)
            core = c
        }
    }

    /// Fetches remote config and starts collecting (after consent when the site requires it).
    public static func initialize(_ config: TapCubConfig? = nil, completion: (() -> Void)? = nil) {
        if let config { preInit(config) }
        queue.async {
            guard let c = core else { return }
            c.initialize {
                if let completion { DispatchQueue.main.async(execute: completion) }
            }
        }
    }

    private static func run(_ f: @escaping (TapCubCore) -> Void) {
        queue.async { if let c = core { f(c) } }
    }

    private static func read<T>(_ fallback: T, _ f: (TapCubCore) -> T) -> T {
        if DispatchQueue.getSpecific(key: onQueue) == true { return core.map(f) ?? fallback }
        return queue.sync { core.map(f) ?? fallback }
    }

    private static func props(_ p: [String: Any]?) -> JSONObject? {
        guard let p else { return nil }
        return JSONValue.from(p as Any).objectValue
    }

    private static func samplePerf() {
        guard let c = core, perfEnabled || c.getRemoteConfig().perf else { return }
        TCPerfSampler.sample { fps, mem in
            run { c in
                if let fps { c.track("$fps_sample", props: props(fps)) }
                if let mem { c.track("$memory_sample", props: props(mem)) }
            }
        }
    }

    // MARK: collection

    public static func track(_ name: String, props p: [String: Any]? = nil) {
        let o = props(p)
        run { $0.track(name, props: o) }
    }
    public static func trackScreen(_ name: String, props p: [String: Any]? = nil) {
        let o = props(p)
        run { $0.trackScreen(name, props: o) }
    }
    public static func flush() { run { $0.flush() } }

    // MARK: identity

    /// type: login | email | mobile | unionid | openid | custom (email / mobile are hashed on device).
    public static func login(_ id: String, props p: [String: Any]? = nil, type: String = "login") {
        let o = props(p)
        run { $0.login(id, props: o, type: type) }
    }
    public static func logout() { run { $0.logout() } }
    public static func bind(_ ids: [String: String]) {
        let o = props(ids)
        run { $0.bind(o ?? JSONObject()) }
    }
    /// User profile set (not super properties; see `registerSuperProps`).
    public static func setProps(_ p: [String: Any]) {
        let o = props(p) ?? JSONObject()
        run { $0.setProps(o) }
    }
    public static func setPropsOnce(_ p: [String: Any]) {
        let o = props(p) ?? JSONObject()
        run { $0.setPropsOnce(o) }
    }
    public static func unsetProps(_ keys: [String]) { run { $0.unsetProps(keys) } }
    public static func setGroup(_ type: String, id: String?, traits: [String: Any]? = nil) {
        let o = props(traits)
        run { $0.setGroup(type, id: id, traits: o) }
    }
    public static func reset() { run { $0.reset() } }
    public static func anonymize() { run { $0.anonymize() } }

    // MARK: consent

    /// purposes: analytics | functional | marketing
    public static func grantConsent(_ purposes: [String]) { run { $0.grantConsent(purposes) } }
    public static func grantConsent(bits: Int) { run { $0.grantConsent(bits: bits) } }
    public static func revokeConsent() { run { $0.revokeConsent() } }
    public static func getConsent() -> Int { read(0) { $0.getConsent() } }
    public static func optOut() { run { $0.optOut() } }
    public static func optIn() { run { $0.optIn() } }
    public static func setRestricted(_ on: Bool) { run { $0.setRestricted(on) } }
    public static func setChildMode(_ on: Bool) { run { $0.setChildMode(on) } }
    /// eu | us | cn — before `initialize`.
    public static func setDataRegion(_ region: String) { run { $0.setDataRegion(region) } }
    public static func shouldPrompt() -> Bool { read(true) { $0.shouldPrompt() } }
    public static func stop() { run { $0.stop() } }
    public static func start() { run { $0.start() } }

    // MARK: properties / commerce

    public static func registerSuperProps(_ p: [String: Any]) {
        let o = props(p) ?? JSONObject()
        run { $0.registerSuperProps(o) }
    }
    public static func unregisterSuperProp(_ key: String) { run { $0.unregisterSuperProp(key) } }
    public static func trackPurchase(_ info: [String: Any]) {
        let o = props(info) ?? JSONObject()
        run { $0.trackPurchase(o) }
    }
    public static func trackPushClick(_ payload: [String: Any]) {
        let o = props(payload) ?? JSONObject()
        run { $0.trackPushClick(o) }
    }
    public static func setAttribution(_ attrs: [String: Any]) {
        let o = props(attrs) ?? JSONObject()
        run { $0.setAttribution(o) }
    }
    public static func trackDeeplink(_ url: String, referrer: String? = nil) { run { $0.trackDeeplink(url, referrer: referrer) } }
    public static func reportException(_ ev: TCCrashEvent) { run { $0.reportException(ev) } }

    // MARK: getters / listeners

    public static func getDeviceId() -> String? { read(nil) { $0.getDeviceId() } }
    public static func getSessionId() -> String? { read(nil) { $0.getSessionId() } }
    public static func getRemoteConfig() -> TCRemoteConfig { read(TCRemoteConfig()) { $0.getRemoteConfig() } }
    public static func getState() -> TCState? { read(nil) { $0.getState() } }
    public static func requiredPrivacyApis() -> [String] { [] }

    public static func onConsentChange(_ cb: @escaping (Int) -> Void) {
        run { $0.onConsentChange { c in DispatchQueue.main.async { cb(c) } } }
    }
    public static func onSessionStart(_ cb: @escaping (_ sessionId: String, _ reason: String) -> Void) {
        run { $0.onSessionStart { s, r in DispatchQueue.main.async { cb(s, r) } } }
    }
    public static func onError(_ cb: @escaping (_ code: String, _ message: String) -> Void) {
        run { $0.onError { c, m in DispatchQueue.main.async { cb(c, m) } } }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Skips automatic `$screen_view` for a view controller class (or a screen name).
    public static func ignoreScreen(_ cls: AnyClass) {
        DispatchQueue.main.async { TCScreenTracker.ignored.insert(NSStringFromClass(cls)) }
    }
    public static func ignoreScreen(named name: String) {
        DispatchQueue.main.async { TCScreenTracker.ignored.insert(name) }
    }
    #endif
}

/// Objective-C entry point with the most common calls.
@objc(TapCubSDK)
public final class TapCubSDK: NSObject {
    @objc public static func preInit(siteKey: String, endpoint: String?, appId: String?) {
        TapCub.preInit(TapCubConfig(siteKey: siteKey, endpoint: endpoint, appId: appId))
    }
    /// Same as `TapCub.initialize()` (`+initialize` is reserved by NSObject).
    @objc public static func start() { TapCub.initialize() }
    @objc public static func track(_ name: String, properties: [String: Any]?) { TapCub.track(name, props: properties) }
    @objc public static func trackScreen(_ name: String, properties: [String: Any]?) { TapCub.trackScreen(name, props: properties) }
    @objc public static func login(_ id: String) { TapCub.login(id) }
    @objc public static func logout() { TapCub.logout() }
    @objc public static func grantConsent(_ purposes: [String]) { TapCub.grantConsent(purposes) }
    @objc public static func optOut() { TapCub.optOut() }
    @objc public static func optIn() { TapCub.optIn() }
    @objc public static func flush() { TapCub.flush() }
    @objc public static func deviceId() -> String? { TapCub.getDeviceId() }
}

#if canImport(SwiftUI) && !os(watchOS)
@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension View {
    /// SwiftUI screens are not auto-tracked; add `.wcScreen("Checkout")` to the screen's root view.
    func wcScreen(_ name: String, props: [String: Any]? = nil) -> some View {
        onAppear { TapCub.trackScreen(name, props: props) }
    }
}
#endif
