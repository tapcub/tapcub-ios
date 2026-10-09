import Foundation
import XCTest
@testable import TapCubCore

/// Runs packages/shared/test-vectors/sdk against the Swift core. Mini-program-only vectors are skipped
/// with the same filter as packages/app-sdk/test/vectors.test.mjs.
final class VectorTests: XCTestCase {
    static let miniProgramOnly = try! NSRegularExpression(pattern: "\\$mp_|mp_uuid|tapcub-mp|mp_weixin|mp_alipay|mp_bytedance|withShareParams|requiredPrivacyApis")

    static var vectorDir: URL {
        if let env = ProcessInfo.processInfo.environment["TC_VECTOR_DIR"] { return URL(fileURLWithPath: env) }
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Main repo: packages/shared/test-vectors/sdk. Public tapcub-ios repo: test-vectors/sdk at the root.
        let candidates = ["../../../shared/test-vectors/sdk", "../../test-vectors/sdk"]
            .map { here.appendingPathComponent($0).standardizedFileURL }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    func testSharedVectors() throws {
        let dir = Self.vectorDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("vector dir not found: \(dir.path)")
        }
        var ran = 0
        var skipped = 0
        var failed: [String] = []
        for f in files.filter({ $0.hasSuffix(".json") }).sorted() {
            let raw = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            guard let v = JSONValue.parse(raw)?.objectValue else {
                XCTFail("\(f): invalid JSON")
                continue
            }
            let isApp = v["suite"]?.stringValue == "app"
                || Self.miniProgramOnly.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) == nil
            if !isApp {
                skipped += 1
                continue
            }
            ran += 1
            do {
                let r = try VectorRunner.run(v)
                if !r.failures.isEmpty {
                    failed.append(f)
                    XCTFail("\(f): \(v["name"]?.stringValue ?? "")\n" + r.failures.joined(separator: "\n"))
                }
            } catch {
                failed.append(f)
                XCTFail("\(f): \(error)")
            }
        }
        print("[vectors] swift ran \(ran) / skipped \(skipped) mini-program-only / failed \(failed.count)")
        XCTAssertGreaterThanOrEqual(ran, 83)
    }
}
