import Foundation
#if canImport(TapCubCore)
import TapCubCore
#endif
#if canImport(UIKit)
import UIKit
#endif

/// App lifecycle → core handlers, delivered on the worker queue.
/// First activation = cold launch (with start duration); willEnterForeground = show; didEnterBackground = hide.
public final class TCAppLifecycle: TCLifecycle {
    private let queue: DispatchQueue
    private let screens: Bool
    private var handlers: TCLifecycleHandlers?
    private var tokens: [NSObjectProtocol] = []
    private var launched = false

    public init(queue: DispatchQueue, autoTrackScreens: Bool) {
        self.queue = queue
        screens = autoTrackScreens
    }

    public func bind(_ h: TCLifecycleHandlers) {
        handlers = h
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func send(_ f: @escaping (TCLifecycleHandlers) -> Void) {
        queue.async { [weak self] in
            guard let h = self?.handlers else { return }
            f(h)
        }
    }

    private func attach() {
        #if canImport(UIKit) && !os(watchOS)
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.launchOnce()
        })
        tokens.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.launched else { return }
            self.send { $0.onShow(TCLaunchInfo()) }
        })
        tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.launched else { return }
            self.send { $0.onHide() }
        })
        if TCBackgroundTask.application?.applicationState == .active { launchOnce() }
        if screens {
            TCScreenTracker.install()
            TCScreenTracker.onShow = { [weak self] page in self?.send { $0.onPageShow(page) } }
            TCScreenTracker.onHide = { [weak self] page in self?.send { $0.onPageHide(page) } }
        }
        #endif
    }

    private func launchOnce() {
        if launched { return }
        launched = true
        var query: [String: String] = [:]
        if let ms = TCProcess.coldStartMs() { query["duration_ms"] = String(ms) }
        send { $0.onLaunch(TCLaunchInfo(query: query)) }
    }
}

enum TCProcess {
    /// Process start → now, or nil when unknown or when iOS pre-warmed the process.
    static func coldStartMs() -> Int64? {
        if ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" { return nil }
        guard let start = startTime() else { return nil }
        let ms = Int64((Date().timeIntervalSince1970 - start) * 1000)
        return ms > 0 && ms < 60_000 ? ms : nil
    }

    static func startTime() -> TimeInterval? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &kinfo, &size, nil, 0) == 0 else { return nil }
        let tv = kinfo.kp_proc.p_un.__p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }
}

#if canImport(UIKit) && !os(watchOS)

/// Lets a view controller choose its screen name; return nil to skip it.
@objc public protocol TapCubScreenNaming {
    var wcScreenName: String? { get }
}

enum TCScreenTracker {
    static var onShow: ((TCPageInfo) -> Void)?
    static var onHide: ((TCPageInfo) -> Void)?
    static var ignored = Set<String>()
    private static var installed = false

    private static let containers: [AnyClass] = [UINavigationController.self, UITabBarController.self, UIPageViewController.self, UISplitViewController.self]

    static func install() {
        if installed { return }
        installed = true
        swizzle(UIViewController.self, #selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.tapcub_viewDidAppear(_:)))
        swizzle(UIViewController.self, #selector(UIViewController.viewDidDisappear(_:)), #selector(UIViewController.tapcub_viewDidDisappear(_:)))
    }

    static func page(for vc: UIViewController) -> TCPageInfo? {
        if containers.contains(where: { vc.isKind(of: $0) }) || vc is UIAlertController { return nil }
        if let parent = vc.parent, !containers.contains(where: { parent.isKind(of: $0) }) { return nil }
        let name: String
        if let n = vc as? TapCubScreenNaming {
            guard let custom = n.wcScreenName, !custom.isEmpty else { return nil }
            name = custom
        } else {
            name = screenName(vc)
            if name.isEmpty { return nil }
        }
        if ignored.contains(name) || ignored.contains(NSStringFromClass(type(of: vc))) { return nil }
        let title = vc.navigationItem.title ?? vc.title
        return TCPageInfo(path: name, title: title)
    }

    static func screenName(_ vc: UIViewController) -> String {
        let raw = String(describing: type(of: vc))
        if raw.hasPrefix("UIHostingController<") { return String(raw.dropFirst("UIHostingController<".count).dropLast()) }
        let objc = NSStringFromClass(type(of: vc))
        if objc.hasPrefix("_") || objc.hasPrefix("UI") { return "" }
        return raw
    }

    static func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let o = class_getInstanceMethod(cls, original), let r = class_getInstanceMethod(cls, replacement) else { return }
        if class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r)) {
            class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o))
        } else {
            method_exchangeImplementations(o, r)
        }
    }
}

extension UIViewController {
    @objc func tapcub_viewDidAppear(_ animated: Bool) {
        tapcub_viewDidAppear(animated)
        if let p = TCScreenTracker.page(for: self) { TCScreenTracker.onShow?(p) }
    }

    @objc func tapcub_viewDidDisappear(_ animated: Bool) {
        tapcub_viewDidDisappear(animated)
        if let p = TCScreenTracker.page(for: self) { TCScreenTracker.onHide?(p) }
    }
}

#endif
