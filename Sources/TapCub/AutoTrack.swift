import Foundation
#if canImport(TapCubCore)
import TapCubCore
#endif
#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

/// `$app_click` auto-capture: every UIControl / UIBarButtonItem action (via `UIApplication.sendAction`)
/// and every UITapGestureRecognizer. Table / collection row selection is not hooked; use `track` there.
/// Swizzles are installed once and gated by `enabled`, so disable/enable is cheap.
public final class TCAutoTrack: TCAutoTrackHook {
    private let queue: DispatchQueue
    static var callback: ((TCElement, TCPageInfo?) -> Void)?

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public func enable(_ cb: @escaping (TCElement, TCPageInfo?) -> Void) {
        let q = queue
        DispatchQueue.main.async {
            TCAutoTrack.callback = { el, page in q.async { cb(el, page) } }
            #if canImport(UIKit) && !os(watchOS)
            TCClickHooks.install()
            #endif
        }
    }

    public func disable() {
        DispatchQueue.main.async { TCAutoTrack.callback = nil }
    }
}

#if canImport(UIKit) && !os(watchOS)

private var wcIdKey: UInt8 = 0
private var wcIgnoreKey: UInt8 = 0

public extension UIView {
    /// Stable element id for `$element_id`; falls back to `accessibilityIdentifier`.
    var tapcubElementId: String? {
        get { objc_getAssociatedObject(self, &wcIdKey) as? String }
        set { objc_setAssociatedObject(self, &wcIdKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    /// Excludes this view (and its subviews) from `$app_click`.
    var wcIgnoreClicks: Bool {
        get { (objc_getAssociatedObject(self, &wcIgnoreKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &wcIgnoreKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

enum TCClickHooks {
    private static var installed = false
    private static var lastSender: ObjectIdentifier?
    private static var lastEventTime: TimeInterval = -1

    static func install() {
        if installed { return }
        installed = true
        TCScreenTracker.swizzle(UIApplication.self, #selector(UIApplication.sendAction(_:to:from:for:)), #selector(UIApplication.tapcub_sendAction(_:to:from:for:)))
        TCScreenTracker.swizzle(UITapGestureRecognizer.self, NSSelectorFromString("setState:"), #selector(UIGestureRecognizer.tapcub_setState(_:)))
    }

    static func action(sender: Any?, event: UIEvent?) {
        guard let cb = TCAutoTrack.callback, let sender = sender as AnyObject? else { return }
        if let touch = event?.allTouches?.first, touch.phase != .ended { return }
        // one control can have several targets; report the tap once
        let sid = ObjectIdentifier(sender)
        let t = event?.timestamp ?? -1
        if sid == lastSender && t == lastEventTime && t >= 0 { return }
        lastSender = sid
        lastEventTime = t
        if let view = sender as? UIView {
            guard !ignored(view) else { return }
            cb(element(view, content: content(of: view)), page(of: view))
        } else if let item = sender as? UIBarButtonItem {
            let el = TCElement(type: "UIBarButtonItem", id: item.accessibilityIdentifier, content: item.title ?? item.accessibilityLabel, path: "UIBarButtonItem[\(item.title ?? "")]")
            cb(el, nil)
        }
    }

    private static let plainTapViews: [AnyClass] = [UIView.self, UIImageView.self, UILabel.self, UIStackView.self]

    /// Taps on UIControls are already reported through sendAction; UIKit-internal recognizers are skipped.
    static func tap(_ gr: UIGestureRecognizer) {
        guard let cb = TCAutoTrack.callback, let view = gr.view, !(view is UIControl), !ignored(view) else { return }
        let name = NSStringFromClass(type(of: view))
        let appClass = !name.hasPrefix("_") && !name.hasPrefix("UI")
        guard appClass || plainTapViews.contains(where: { type(of: view) == $0 }) else { return }
        cb(element(view, content: content(of: view) ?? view.accessibilityLabel), page(of: view))
    }

    static func ignored(_ view: UIView) -> Bool {
        var v: UIView? = view
        while let cur = v {
            if cur.wcIgnoreClicks { return true }
            v = cur.superview
        }
        return false
    }

    static func element(_ view: UIView, content: String?) -> TCElement {
        TCElement(type: String(describing: type(of: view)), id: view.tapcubElementId ?? view.accessibilityIdentifier, content: content, path: path(of: view))
    }

    static func content(of view: UIView) -> String? {
        switch view {
        case let b as UIButton: return b.currentTitle ?? b.accessibilityLabel
        case let l as UILabel: return l.text
        case let s as UISegmentedControl: return s.selectedSegmentIndex >= 0 ? s.titleForSegment(at: s.selectedSegmentIndex) : nil
        case let s as UISwitch: return s.isOn ? "on" : "off"
        default: return view.accessibilityLabel
        }
    }

    /// `Screen/ClassName[index among same-class siblings]/…`, root first.
    static func path(of view: UIView) -> String {
        var parts: [String] = []
        var v: UIView? = view
        var depth = 0
        while let cur = v, depth < 12 {
            if let vc = cur.next as? UIViewController {
                parts.append(TCScreenTracker.page(for: vc)?.path ?? String(describing: type(of: vc)))
                break
            }
            let cls = type(of: cur)
            let idx = cur.superview?.subviews.filter { type(of: $0) == cls }.firstIndex { $0 === cur } ?? 0
            parts.append("\(cls)[\(idx)]")
            v = cur.superview
            depth += 1
        }
        return parts.reversed().joined(separator: "/")
    }

    static func page(of view: UIView) -> TCPageInfo? {
        var r: UIResponder? = view
        while let cur = r {
            if let vc = cur as? UIViewController {
                var c: UIViewController? = vc
                while let x = c {
                    if let p = TCScreenTracker.page(for: x) { return p }
                    c = x.parent
                }
                return nil
            }
            r = cur.next
        }
        return nil
    }
}

extension UIApplication {
    @objc func tapcub_sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: UIEvent?) -> Bool {
        TCClickHooks.action(sender: sender, event: event)
        return tapcub_sendAction(action, to: target, from: sender, for: event)
    }
}

extension UIGestureRecognizer {
    @objc func tapcub_setState(_ state: UIGestureRecognizer.State) {
        tapcub_setState(state)
        if state == .ended { TCClickHooks.tap(self) }
    }
}

#endif
