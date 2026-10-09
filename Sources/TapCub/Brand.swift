import Foundation

/// Every brand-dependent name lives here so the pre-release rename touches one file.
/// Core storage keys use `tc_*` (shared with every SDK, see packages/shared/test-vectors); App-global names use the full `tapcub` (plan §6.3).
enum TapCubBrand {
    static let keychainService = "com.tapcub.sdk"
    static let defaultsPrefix = "tapcub."
    static let supportDir = "TapCub"
    static let workerQueue = "com.tapcub.worker"
    static let logTag = "[TapCub]"
}
