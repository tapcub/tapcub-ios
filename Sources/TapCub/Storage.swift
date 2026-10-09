import Foundation
#if canImport(TapCubCore)
import TapCubCore
#endif

/// Small keys go to UserDefaults; queue chunks (`tc_q*`) go to one file each under
/// Application Support/TapCub/queue, excluded from backup. Rewriting a 40-event chunk then
/// touches one small file instead of the whole defaults plist.
/// `tc_did` is mirrored to the Keychain (survives reinstall). Removing it records a rotation so the
/// next id is generated instead of falling back to IDFV again (otherwise `reset()` would not rotate).
public final class TCDeviceStorage: TCStorage {
    static let didKey = "tc_did"
    static let rotatedKey = "tapcub_did_rotated"

    private let defaults: UserDefaults
    private let queueDir: URL
    private let keychain: Bool

    public init(defaults: UserDefaults = .standard, directory: URL? = nil, keychain: Bool = true) {
        self.defaults = defaults
        self.keychain = keychain
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(TapCubBrand.supportDir, isDirectory: true)
        queueDir = base.appendingPathComponent("queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        var dir = queueDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private func isQueueKey(_ key: String) -> Bool { key.hasPrefix("tc_q") }
    private func file(_ key: String) -> URL { queueDir.appendingPathComponent(key) }

    public func get(_ key: String) -> String? {
        if isQueueKey(key) { return try? String(contentsOf: file(key), encoding: .utf8) }
        return defaults.string(forKey: TapCubBrand.defaultsPrefix + key)
    }

    public func set(_ key: String, _ value: String) throws {
        if isQueueKey(key) {
            try Data(value.utf8).write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            defaults.set(value, forKey: TapCubBrand.defaultsPrefix + key)
            if key == Self.didKey && keychain { TCKeychain.set(key, value) }
        }
    }

    public func remove(_ key: String) {
        if isQueueKey(key) {
            try? FileManager.default.removeItem(at: file(key))
        } else {
            defaults.removeObject(forKey: TapCubBrand.defaultsPrefix + key)
            if key == Self.didKey {
                defaults.set("1", forKey: TapCubBrand.defaultsPrefix + Self.rotatedKey)
                if keychain { TCKeychain.remove(key) }
            }
        }
    }

    /// Device id kept across reinstalls, or nil when none exists yet.
    func persistedDeviceId() -> String? { keychain ? TCKeychain.get(Self.didKey) : nil }

    /// True once the core has dropped a device id on this install.
    var didRotated: Bool { defaults.string(forKey: TapCubBrand.defaultsPrefix + Self.rotatedKey) == "1" }
}

/// In-memory storage for tests and previews.
public final class TCMemoryStorage: TCStorage {
    private var map: [String: String]
    public init(_ seed: [String: String] = [:]) { map = seed }
    public func get(_ key: String) -> String? { map[key] }
    public func set(_ key: String, _ value: String) throws { map[key] = value }
    public func remove(_ key: String) { map.removeValue(forKey: key) }
    public func dump() -> [String: String] { map }
}

/// Keychain persistence for the device id so it survives reinstalls.
enum TCKeychain {
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TapCubBrand.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        remove(key)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TapCubBrand.keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TapCubBrand.keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
