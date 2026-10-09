import Foundation
import CryptoKit

// Mirrors packages/app-sdk/src/core/util.ts. String lengths are UTF-16 code units, as in JS.

enum TCLimits {
    static let name = 100
    static let propKey = 50
    static let propValue = 200
    static let propKeys = 30
    static let presetPropKeys = 40
    static let profileKeys = 50
    static let stack = 4000
    static let message = 1000
    static let url = 4000
    static let title = 200
}

let LOGIN_ID_MAX = 200

final class TCRegex {
    private let re: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool = false) {
        re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
    func test(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

let BLOCKED_ID_RE = TCRegex("^([0-]*|-1|null|undefined|NaN|anonymous|guest|true|false|\\[object Object\\])$", caseInsensitive: true)
let DEVICE_ID_RE = TCRegex("^(web_cookie|web_cookieless|mp_openid|mp_uuid|ios_idfv|android_id|harmony_odid|custom):[A-Za-z0-9_-]{8,64}$")
let HEX64 = TCRegex("^[a-f0-9]{64}$", caseInsensitive: true)

extension String {
    var jsLength: Int { utf16.count }

    /// `String.prototype.slice(0, n)` on UTF-16 code units.
    func jsSlice(_ n: Int) -> String {
        if utf16.count <= n { return self }
        let units = Array(utf16.prefix(Swift.max(0, n)))
        return String(decoding: units, as: UTF16.self)
    }

    var jsTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// JS `Math.round`.
func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

/// JS `Number(v)` for values the remote config can carry.
func jsNumber(_ v: JSONValue?) -> Double {
    switch v {
    case .some(.number(let n)): return n
    case .some(.string(let s)):
        let t = s.jsTrimmed
        if t.isEmpty { return 0 }
        return Double(t) ?? .nan
    default: return .nan
    }
}

func clampInt(_ v: JSONValue?, _ lo: Int, _ hi: Int, _ d: Int) -> Int {
    var n: Double
    switch v {
    case .some(.number(let x)): n = x
    case .some(.string): n = jsNumber(v)
    default: n = .nan
    }
    if !n.isFinite { return d }
    n = jsRound(n)
    return Int(Swift.min(Double(hi), Swift.max(Double(lo), n)))
}

func strList(_ v: JSONValue?, _ max: Int, _ len: Int) -> [String] {
    guard let a = v?.arrayValue else { return [] }
    return Array(a.compactMap { x -> String? in
        guard let s = x.stringValue, s.jsLength > 0, s.jsLength <= len else { return nil }
        return s
    }.prefix(max))
}

private let SEMVER_RE = TCRegex("^\\d+\\.\\d+\\.\\d+$")

func normalizeRc(_ raw: JSONValue?) -> TCRemoteConfig {
    let r = raw?.objectValue ?? JSONObject()
    let d = TCRemoteConfig()
    var o = TCRemoteConfig()
    var mv: String?
    if let s = r["minVersion"]?.stringValue, SEMVER_RE.test(s.jsTrimmed) { mv = s.jsTrimmed }
    o.enabled = r["enabled"] != .bool(false)
    o.blacklist = strList(r["blacklist"], 50, 100)
    o.sample = clampInt(r["sample"], 1, 100, d.sample)
    o.interval = clampInt(r["interval"], 10, 1800, d.interval)
    o.threshold = clampInt(r["threshold"], 10, 1000, d.threshold)
    o.deviceBlacklist = strList(r["deviceBlacklist"], 50, 80)
    o.requireConsent = r["requireConsent"] == .bool(true)
    o.autotrack = r["autotrack"] != .bool(false)
    o.textCapture = r["textCapture"] == .bool(true)
    o.elementBlacklist = strList(r["elementBlacklist"], 50, 120)
    o.perf = r["perf"] == .bool(true)
    o.minVersion = mv
    o.ttl = clampInt(r["ttl"], 300, 604800, d.ttl)
    return o
}

/// JS `parseInt(x, 10) || 0`.
private func leadingInt(_ s: String) -> Int {
    var t = Substring(s.jsTrimmed)
    var sign = 1
    if t.first == "-" { sign = -1; t = t.dropFirst() } else if t.first == "+" { t = t.dropFirst() }
    let digits = t.prefix { $0.isASCII && $0.isNumber }
    return (Int(digits) ?? 0) * sign
}

func compareSemver(_ a: String, _ b: String) -> Int {
    let pa = a.split(separator: ".", omittingEmptySubsequences: false).map { leadingInt(String($0)) }
    let pb = b.split(separator: ".", omittingEmptySubsequences: false).map { leadingInt(String($0)) }
    for i in 0..<3 {
        let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
        if d != 0 { return d < 0 ? -1 : 1 }
    }
    return 0
}

func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func randomHex(_ random: () -> Double, _ n: Int) -> String {
    var a: [UInt8] = []
    a.reserveCapacity(n)
    for _ in 0..<n { a.append(UInt8(Int((random() * 256).rounded(.down)) & 255)) }
    return hexString(a)
}

func uuidV4(_ random: () -> Double) -> String {
    var h = Array(randomHex(random, 16))
    h[12] = "4"
    let v = (Int(String(h[16]), radix: 16) ?? 0) & 3 | 8
    h[16] = Character(String(v, radix: 16))
    let s = String(h)
    func part(_ a: Int, _ b: Int) -> Substring { s[s.index(s.startIndex, offsetBy: a)..<s.index(s.startIndex, offsetBy: b)] }
    return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
}

/// FNV-1a 32-bit over UTF-16 code units (sampling by device id).
func fnv1a(_ s: String) -> UInt32 {
    var h: UInt32 = 0x811c9dc5
    for c in s.utf16 {
        h ^= UInt32(c)
        h = h &* 0x01000193
    }
    return h
}

func sha256(_ text: String) -> String {
    hexString(SHA256.hash(data: Data(text.utf8)))
}

private let SPACES_DASHES = TCRegex("[\\s-]")

func normId(_ t: String, _ v: String) -> String {
    if t == "email" { return v.jsTrimmed.lowercased() }
    if t == "mobile" { return SPACES_DASHES.replace(v, with: "") }
    return v.jsTrimmed
}

/// Property normalization: keys ≤ 50, values ≤ 200; `$` preset keys and user keys counted separately.
func normProps(_ input: JSONObject?, _ userMax: Int = TCLimits.propKeys, _ presetMax: Int = TCLimits.presetPropKeys) -> JSONObject? {
    guard let input else { return nil }
    var out = JSONObject()
    var user = 0
    var preset = 0
    input.forEach { k, v in
        if v.isNull || k.isEmpty || k.jsLength > TCLimits.propKey { return }
        if k.hasPrefix("$") {
            if preset >= presetMax { return }
            preset += 1
        } else {
            if user >= userMax { return }
            user += 1
        }
        switch v {
        case .string(let s): out[k] = .string(s.jsSlice(TCLimits.propValue))
        case .number(let n): out[k] = .number(n.isFinite ? n : 0)
        case .bool: out[k] = v
        default: out[k] = .string(v.stringify().jsSlice(TCLimits.propValue))
        }
    }
    return out
}

func safeParseObject(_ s: String?) -> JSONObject? {
    JSONValue.parse(s)?.objectValue
}

func byteLength(_ s: String) -> Int { s.utf8.count }

/// Deterministic PRNG used by the test vectors (same as mock.mjs `mulberry32`).
public final class Mulberry32 {
    private var a: UInt32
    public init(seed: UInt32) { a = seed }
    public func next() -> Double {
        a = a &+ 0x6d2b79f5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}
