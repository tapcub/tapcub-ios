import Foundation
#if canImport(TapCubCore)
import TapCubCore
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Dedicated ephemeral URLSession (never the host's `URLSession.shared`). Completions are delivered
/// on the worker queue. Each POST holds a background task so a batch can finish after the app is backgrounded.
public final class TCURLSessionTransport: TCTransport {
    private let session: URLSession
    private let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    public func get(_ url: String, completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
        guard let u = URL(string: url) else {
            queue.async { completion(.failure(URLError(.badURL))) }
            return
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 10
        run(req, completion)
    }

    public func post(_ url: String, body: String, headers: [String: String], completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
        guard let u = URL(string: url) else {
            queue.async { completion(.failure(URLError(.badURL))) }
            return
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = TCBackgroundTask.begin()
        run(req) { r in
            completion(r)
            task.end()
        }
    }

    private func run(_ req: URLRequest, _ completion: @escaping (Result<TCTransportResponse, Error>) -> Void) {
        let q = queue
        session.dataTask(with: req) { data, res, err in
            let r: Result<TCTransportResponse, Error>
            if let err {
                r = .failure(err)
            } else {
                let code = (res as? HTTPURLResponse)?.statusCode ?? 0
                r = .success(TCTransportResponse(status: code, body: data.flatMap { String(data: $0, encoding: .utf8) }))
            }
            q.async { completion(r) }
        }.resume()
    }
}

/// `UIApplication.shared` is unavailable in app extensions, so it is looked up dynamically.
final class TCBackgroundTask {
    #if canImport(UIKit) && !os(watchOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    private let lock = NSLock()

    static var application: UIApplication? {
        let sel = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sel) else { return nil }
        return UIApplication.perform(sel)?.takeUnretainedValue() as? UIApplication
    }

    static func begin() -> TCBackgroundTask {
        let t = TCBackgroundTask()
        if let app = application {
            t.id = app.beginBackgroundTask(withName: "tapcub-flush") { [weak t] in t?.end() }
        }
        return t
    }

    func end() {
        lock.lock()
        let current = id
        id = .invalid
        lock.unlock()
        if current != .invalid { TCBackgroundTask.application?.endBackgroundTask(current) }
    }
    #else
    static func begin() -> TCBackgroundTask { TCBackgroundTask() }
    func end() {}
    #endif
}
