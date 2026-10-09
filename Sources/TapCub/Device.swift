import Foundation
import Network
#if canImport(TapCubCore)
import TapCubCore
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Device info for iOS. UIKit values (idiom, screen) are captured on the main thread when the SDK is
/// created; `read()` itself runs on the worker queue and never touches UIKit. The IDFV and Keychain
/// are only read from `deviceId()`, which the core calls after consent.
public final class TCSystemDevice: TCDeviceInfo {
    public let platform = "ios"
    private let storage: TCDeviceStorage?
    private let lock = NSLock()
    private var idiom = "phone"
    private var screen: (w: Int, h: Int, scale: Double)?
    private var path: String = "unknown"
    private var monitor: AnyObject?
    private let queue: DispatchQueue

    public init(queue: DispatchQueue, storage: TCDeviceStorage? = nil) {
        self.queue = queue
        self.storage = storage
        if Thread.isMainThread {
            captureUI()
        } else {
            DispatchQueue.main.async { [weak self] in self?.captureUI() }
        }
    }

    private func captureUI() {
        #if canImport(UIKit) && !os(watchOS)
        let i: String
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: i = "tablet"
        case .tv: i = "tv"
        case .phone: i = "phone"
        default: i = "other"
        }
        let b = UIScreen.main.nativeBounds
        let s = (Int(min(b.width, b.height)), Int(max(b.width, b.height)), Double(UIScreen.main.nativeScale))
        lock.lock()
        idiom = i
        screen = s
        lock.unlock()
        #endif
    }

    public func read() -> TCDeviceSnapshot {
        lock.lock()
        let i = idiom
        let sc = screen
        lock.unlock()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        let lang = Self.languageTag(Locale.preferredLanguages.first ?? Locale.current.identifier)
        return TCDeviceSnapshot(
            os: "iOS",
            osVersion: osVersion,
            brand: "Apple",
            model: Self.machine(),
            deviceType: i,
            screenWidth: sc?.w,
            screenHeight: sc?.h,
            pixelRatio: sc?.scale,
            locale: lang,
            timezone: TimeZone.current.identifier
        )
    }

    /// `zh-Hans-CN` → `zh-CN`, `zh-Hant` → `zh-TW`, `en-US` unchanged (same shape as the other SDKs).
    static func languageTag(_ raw: String) -> String {
        let parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let lang = parts.first else { return raw }
        let script = parts.dropFirst().first { $0.count == 4 }
        if let region = parts.dropFirst().first(where: { $0.count == 2 || ($0.count == 3 && Int($0) != nil) }) {
            return "\(lang)-\(region.uppercased())"
        }
        if lang == "zh", let script { return script == "Hant" ? "zh-TW" : "zh-CN" }
        return lang
    }

    /// Hardware model code such as `iPhone15,2` (simulators report the simulated model).
    static func machine() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public func networkType(_ completion: @escaping (String?) -> Void) {
        if monitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] p in
                let t: String
                if p.status != .satisfied { t = "none" }
                else if p.usesInterfaceType(.wifi) { t = "wifi" }
                else if p.usesInterfaceType(.cellular) { t = "cellular" }
                else if p.usesInterfaceType(.wiredEthernet) { t = "ethernet" }
                else { t = "unknown" }
                self?.lock.lock()
                self?.path = t
                self?.lock.unlock()
            }
            m.start(queue: DispatchQueue.global(qos: .utility))
            monitor = m
            // first update arrives asynchronously; report it once it is there
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let t = self.path
                self.lock.unlock()
                self.queue.async { completion(t) }
            }
            return
        }
        lock.lock()
        let t = path
        lock.unlock()
        queue.async { completion(t) }
    }

    public func deviceId() -> String? {
        if let kept = storage?.persistedDeviceId(), !kept.isEmpty { return kept }
        if storage?.didRotated == true { return nil }
        #if canImport(UIKit) && !os(watchOS)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString { return "ios_idfv:\(idfv.lowercased())" }
        #endif
        return nil
    }
}
