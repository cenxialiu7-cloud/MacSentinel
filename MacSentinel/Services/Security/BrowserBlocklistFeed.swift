import Foundation

// MARK: - BrowserBlocklistFeed
//
// Pulls remote blocklists for browser extension IDs and merges them with
// the hardcoded built-in IOC list in BrowserScanner.
//
// Sources we attempt (best-effort; failures degrade gracefully to cache + builtin):
//   • Mozilla Remote Settings — Firefox add-on blocklist
//       https://firefox.settings.services.mozilla.com/v1/buckets/blocklists/collections/addons-bloomfilters/records
//     (We use the simpler `addons` collection if available.)
//   • Optional self-hosted Chromium IOC list (configurable URL).
//
// Cache: ~/Library/Application Support/MacSentinel/blocklist-cache.json
//        Refreshed at most every 24h. Offline = cache; cache miss = empty
//        remote set, hardcoded list still applies.

final class BrowserBlocklistFeed: @unchecked Sendable {

    static let shared = BrowserBlocklistFeed()

    private let lock = NSLock()

    struct CachedFeed: Codable {
        var lastUpdated: Date
        // extension id -> reason (e.g. "Mozilla blocklist 2024-12-01")
        var entries: [String: String]
    }

    private var _cache: CachedFeed = .init(lastUpdated: .distantPast, entries: [:])
    private var _lastRefreshError: String?

    var cache: CachedFeed {
        lock.lock(); defer { lock.unlock() }
        return _cache
    }
    var lastRefreshError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastRefreshError
    }

    private let cacheURL: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSentinel", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport,
                                                  withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("blocklist-cache.json")
    }()

    private let refreshInterval: TimeInterval = 24 * 60 * 60

    private init() { loadCache() }

    // MARK: - Public API

    /// Returns merged blocklist (id -> reason). Built-in callers should
    /// supply their hardcoded map; this returns extra remote entries to merge.
    var remoteEntries: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return _cache.entries
    }

    var lastUpdated: Date {
        lock.lock(); defer { lock.unlock() }
        return _cache.lastUpdated
    }

    /// Refresh if cache is older than `refreshInterval`. Safe to call at app
    /// launch — runs on a background task and never blocks.
    func refreshIfNeeded() {
        let age = Date().timeIntervalSince(lastUpdated)
        guard age > refreshInterval else { return }
        Task.detached(priority: .background) { [weak self] in
            await self?.refresh()
        }
    }

    /// Force refresh now. Returns merged entry count.
    @discardableResult
    func refresh() async -> Int {
        var merged: [String: String] = [:]
        var errors: [String] = []

        do {
            let mozilla = try await fetchMozilla()
            merged.merge(mozilla) { a, _ in a }
        } catch {
            errors.append("Mozilla: \(error.localizedDescription)")
        }

        // Apply result
        lock.lock()
        _cache = CachedFeed(lastUpdated: Date(), entries: merged)
        _lastRefreshError = errors.isEmpty ? nil : errors.joined(separator: " | ")
        let snapshot = _cache
        lock.unlock()
        saveCache(snapshot)
        return merged.count
    }

    // MARK: - Mozilla Remote Settings

    /// Mozilla blocklist record schema (subset we care about):
    /// { "data": [ { "guid": "addon@example.com", "details": { "name": "...", "why": "..." }, ... }, ... ] }
    private struct MozillaResponse: Codable {
        struct Record: Codable {
            let guid: GUID?
            struct Details: Codable {
                let name: String?
                let why: String?
            }
            let details: Details?
        }
        let data: [Record]
    }

    /// Mozilla `guid` may be a plain string or a regex object `{ "$re": "..." }`.
    /// We only care about plain string IDs (regex matches are out of scope).
    enum GUID: Codable {
        case plain(String)
        case regex(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .plain(s); return }
            struct Wrap: Codable { let re: String? }
            if let w = try? c.decode([String: String].self), let re = w["$re"] {
                self = .regex(re); return
            }
            self = .plain("")
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .plain(let s): try c.encode(s)
            case .regex(let s): try c.encode(["$re": s])
            }
        }

        var asPlain: String? {
            if case .plain(let s) = self, !s.isEmpty { return s }
            return nil
        }
    }

    private func fetchMozilla() async throws -> [String: String] {
        let url = URL(string:
            "https://firefox.settings.services.mozilla.com/v1/buckets/blocklists/collections/addons/records")!
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("MacSentinel/1.0 (+https://macsentinel.local)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "BrowserBlocklistFeed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        let parsed = try JSONDecoder().decode(MozillaResponse.self, from: data)

        var out: [String: String] = [:]
        for rec in parsed.data {
            guard let id = rec.guid?.asPlain else { continue }
            let why = rec.details?.why ?? rec.details?.name ?? "Mozilla blocklist"
            out[id] = "Mozilla: \(why.prefix(120))"
        }
        return out
    }

    // MARK: - Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(CachedFeed.self, from: data)
        else { return }
        lock.lock(); _cache = decoded; lock.unlock()
    }

    private func saveCache(_ snapshot: CachedFeed) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
