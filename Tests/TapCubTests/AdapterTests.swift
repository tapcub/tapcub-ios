import XCTest
@testable import TapCub

final class AdapterTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private let suite = "tapcub.tests.\(UUID().uuidString)"

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    func testQueueKeysGoToFilesOtherKeysToDefaults() throws {
        let s = TCDeviceStorage(defaults: defaults, directory: dir, keychain: false)
        try s.set("tc_q_0", "[1,2]")
        try s.set("tc_sid", "abc")
        XCTAssertEqual(s.get("tc_q_0"), "[1,2]")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue/tc_q_0").path))
        XCTAssertNil(defaults.string(forKey: "tapcub.tc_q_0"))
        XCTAssertEqual(defaults.string(forKey: "tapcub.tc_sid"), "abc")
        s.remove("tc_q_0")
        XCTAssertNil(s.get("tc_q_0"))
    }

    func testRemovingDeviceIdMarksRotation() throws {
        let s = TCDeviceStorage(defaults: defaults, directory: dir, keychain: false)
        try s.set("tc_did", "ios_idfv:0123456789abcdef")
        XCTAssertFalse(s.didRotated)
        s.remove("tc_did")
        XCTAssertTrue(s.didRotated)
        XCTAssertNil(s.get("tc_did"))
    }

    func testSignalRecordParsesTypeTimeAndFrames() {
        let ev = TCCrashReporter.parseSignalRecord("TCSIG 11 1699999000\nApp+0x1a2b\n0x10002000\n")
        XCTAssertEqual(ev?.type, "SIGSEGV")
        XCTAssertEqual(ev?.ts, 1_699_999_000_000)
        XCTAssertEqual(ev?.stack, "App+0x1a2b\n0x10002000")
        XCTAssertEqual(ev?.fatal, true)
        XCTAssertNil(TCCrashReporter.parseSignalRecord("garbage"))
        XCTAssertNil(TCCrashReporter.parseSignalRecord(""))
    }

    func testPendingExceptionRecordIsConsumedOnce() throws {
        let r = TCCrashReporter(queue: DispatchQueue(label: "t"), directory: dir)
        let json = #"{"type":"NSRangeException","message":"index 3 beyond bounds","stack":"App+0x10","foreground":true,"ts":1699999000000}"#
        try Data(json.utf8).write(to: r.exceptionFile)
        let first = r.consumePending()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].type, "NSRangeException")
        XCTAssertEqual(first[0].ts, 1_699_999_000_000)
        XCTAssertTrue(r.consumePending().isEmpty)
        r.rememberRecent(first)
        XCTAssertEqual(r.recent().first?.ts, 1_699_999_000_000)
    }

    func testLanguageTagDropsScript() {
        XCTAssertEqual(TCSystemDevice.languageTag("zh-Hans-CN"), "zh-CN")
        XCTAssertEqual(TCSystemDevice.languageTag("zh-Hant"), "zh-TW")
        XCTAssertEqual(TCSystemDevice.languageTag("en-US"), "en-US")
        XCTAssertEqual(TCSystemDevice.languageTag("es-419"), "es-419")
        XCTAssertEqual(TCSystemDevice.languageTag("ja"), "ja")
    }

    func testMemorySampleReportsMegabytes() {
        let m = TCPerfSampler.memorySample()
        XCTAssertNotNil(m?["$memory_mb"] as? Int)
    }

    func testCoreRunsOnRealAdaptersAndPostsBatch() {
        let q = DispatchQueue(label: "tapcub.test.worker")
        let storage = TCDeviceStorage(defaults: defaults, directory: dir, keychain: false)
        let transport = StubTransport(queue: q)
        let posted = expectation(description: "collect posted")
        transport.onPost = { url, body in
            if body.contains("\"n\":\"checkout\"") {
                XCTAssertTrue(url.hasSuffix("/api/v1/pulse"))
                XCTAssertTrue(body.contains("\"pt\":\"ios\""))
                posted.fulfill()
            }
        }
        let adapters = TCAdapters(
            storage: storage,
            transport: transport,
            lifecycle: NoLifecycle(),
            device: TCSystemDevice(queue: q, storage: storage),
            timers: TCDispatchTimers(queue: q)
        )
        q.async {
            let core = TapCubCore(adapters)
            core.preInit(TapCubConfig(siteKey: "s_test", endpoint: "https://collect.test", appId: "com.tapcub.demo", reportPolicy: TCPartialPolicy(threshold: 1)))
            core.initialize {
                core.track("checkout", props: ["amount": .number(9.9)])
            }
        }
        wait(for: [posted], timeout: 5)
    }
}

private final class StubTransport: TCTransport {
    let queue: DispatchQueue
    var onPost: ((String, String) -> Void)?
    init(queue: DispatchQueue) { self.queue = queue }
    func get(_ url: String, completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
        queue.async { completion(.success(TCTransportResponse(status: 200, body: #"{"t":3,"i":1,"cs":{"req":false}}"#))) }
    }
    func post(_ url: String, body: String, headers: [String: String], completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
        queue.async {
            self.onPost?(url, body)
            completion(.success(TCTransportResponse(status: 200, body: "{}")))
        }
    }
}

private final class NoLifecycle: TCLifecycle {
    func bind(_ handlers: TCLifecycleHandlers) {}
}
