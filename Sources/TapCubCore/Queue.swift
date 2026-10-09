import Foundation

// Mirrors packages/app-sdk/src/core/queue.ts: in-memory mirror + storage chunks `tc_q_{n}`, index `tc_q_i`.

private let CHUNK_ITEMS = 40
private let IDX = "tc_q_i"
private func key(_ n: Int) -> String { "tc_q_\(n)" }

final class PersistentQueue {
    private struct Chunk {
        var n: Int
        var items: [JSONObject]
        var bytes: Int
    }

    private var chunks: [Chunk] = []
    private var mids = Set<String>()
    private var first = 0
    private var last = -1
    private var persistent = false

    private let storage: TCStorage
    private let limits: TCQueueLimits
    private let now: () -> Int64
    private let onError: (String, String) -> Void

    init(storage: TCStorage, limits: TCQueueLimits, now: @escaping () -> Int64, onError: @escaping (String, String) -> Void) {
        self.storage = storage
        self.limits = limits
        self.now = now
        self.onError = onError
    }

    func load() {
        persistent = true
        let idx = safeParseObject(safeGet(IDX))
        let mem = chunks
        chunks = []
        mids.removeAll()
        if let idx, let f = idx["f"]?.numberValue, let l = idx["l"]?.numberValue, f.isFinite, l.isFinite, l >= f, l - f < 10000 {
            let minTs = Double(now()) - Double(limits.maxDays) * 86_400_000
            for n in Int(f)...Int(l) {
                let raw = safeGet(key(n))
                let items = (JSONValue.parse(raw)?.arrayValue ?? []).compactMap { v -> JSONObject? in
                    guard let p = v.objectValue, p["mid"]?.stringValue != nil else { return nil }
                    if let ts = p["ts"]?.numberValue, ts < minTs { return nil }
                    return p
                }
                if items.isEmpty {
                    safeRemove(key(n))
                    continue
                }
                for p in items { mids.insert(p["mid"]!.stringValue!) }
                chunks.append(Chunk(n: n, items: items, bytes: raw.map(byteLength) ?? 0))
            }
            first = Int(f)
            last = Int(l)
        }
        if chunks.isEmpty {
            first = 0
            last = -1
        }
        for c in mem { for p in c.items { _ = push(p) } }
        enforce()
        writeIndex()
    }

    func purge() {
        for c in chunks { safeRemove(key(c.n)) }
        safeRemove(IDX)
        chunks = []
        mids.removeAll()
        first = 0
        last = -1
        persistent = false
    }

    var length: Int { chunks.reduce(0) { $0 + $1.items.count } }
    var bytes: Int { chunks.reduce(0) { $0 + $1.bytes } }
    var loaded: Bool { persistent }

    @discardableResult
    func push(_ p: JSONObject) -> Bool {
        guard let mid = p["mid"]?.stringValue, !mids.contains(mid) else { return false }
        if chunks.isEmpty || chunks[chunks.count - 1].items.count >= CHUNK_ITEMS {
            last += 1
            if chunks.isEmpty { first = last }
            chunks.append(Chunk(n: last, items: [], bytes: 0))
            writeIndex()
        }
        chunks[chunks.count - 1].items.append(p)
        mids.insert(mid)
        writeChunk(chunks.count - 1)
        enforce()
        return true
    }

    func peek() -> [JSONObject] {
        var out: [JSONObject] = []
        var size = 2
        for c in chunks {
            for p in c.items {
                let b = byteLength(p.stringify()) + 1
                if !out.isEmpty && (out.count >= limits.maxBatch || size + b > limits.maxBytes) { return out }
                out.append(p)
                size += b
                if out.count >= limits.maxBatch { return out }
            }
        }
        return out
    }

    func ack(_ items: [JSONObject]) {
        var set = Set(items.compactMap { $0["mid"]?.stringValue })
        var i = 0
        while i < chunks.count && !set.isEmpty {
            let before = chunks[i].items.count
            chunks[i].items.removeAll { p in
                guard let m = p["mid"]?.stringValue, set.contains(m) else { return false }
                set.remove(m)
                mids.remove(m)
                return true
            }
            if chunks[i].items.count == before {
                i += 1
                continue
            }
            if chunks[i].items.isEmpty {
                let n = chunks[i].n
                chunks.remove(at: i)
                safeRemove(key(n))
                first = chunks.first?.n ?? last + 1
                writeIndex()
            } else {
                writeChunk(i)
                i += 1
            }
        }
    }

    private func enforce() {
        var dropped = 0
        while length > limits.maxEvents || bytes > limits.maxStorageBytes {
            guard !chunks.isEmpty else { break }
            let headCount = chunks[0].items.count
            let excessItems = length - limits.maxEvents
            let take = bytes > limits.maxStorageBytes
                ? max(1, Int((Double(headCount) / 2).rounded(.up)))
                : min(max(1, excessItems), headCount)
            for j in 0..<min(take, headCount) {
                if let m = chunks[0].items[j]["mid"]?.stringValue { mids.remove(m) }
            }
            chunks[0].items.removeFirst(min(take, headCount))
            dropped += take
            if chunks[0].items.isEmpty {
                let n = chunks[0].n
                chunks.removeFirst()
                safeRemove(key(n))
                first = chunks.first?.n ?? last + 1
                writeIndex()
            } else {
                writeChunk(0)
            }
        }
        if dropped > 0 { onError("queue_overflow", "dropped \(dropped) oldest events") }
    }

    private func writeChunk(_ i: Int) {
        let s = JSONValue.array(chunks[i].items.map { .object($0) }).stringify()
        chunks[i].bytes = byteLength(s)
        guard persistent else { return }
        do {
            try storage.set(key(chunks[i].n), s)
        } catch {
            onError("storage_failed", String(describing: error))
        }
    }

    private func writeIndex() {
        guard persistent else { return }
        do {
            if !chunks.isEmpty {
                try storage.set(IDX, JSONObject(dictionaryLiteral: ("f", .number(Double(first))), ("l", .number(Double(last)))).stringify())
            } else {
                storage.remove(IDX)
            }
        } catch {
            onError("storage_failed", String(describing: error))
        }
    }

    private func safeGet(_ k: String) -> String? { storage.get(k) }

    private func safeRemove(_ k: String) {
        guard persistent else { return }
        storage.remove(k)
    }
}
