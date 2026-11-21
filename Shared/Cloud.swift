import Foundation
import GigCore

/// Supabase sync. Used by both the app and the screen reader, so they can share data even when
/// iOS doesn't give them shared storage (free sideloaded installs):
/// - the screen reader uploads every offer + screenshot, and loads your targets, banner choices,
///   route and location from the cloud;
/// - the app uploads those settings, marks offers Accepted/Declined, and downloads the offer log.
/// Changes are queued on the phone and retried, so weak signal doesn't lose anything.
extension OfferRecord {
    func withLocations(pickup: Coord?, dropoff: Coord?, estimated: Bool?) -> OfferRecord {
        var r = self
        r.pickupLocation = pickup
        r.dropoffLocation = dropoff
        r.dropoffEstimated = estimated
        return r
    }
}

enum MapEstimate {
    static let label = "Customer (estimated from map)"
}

actor Cloud {
    static let shared = Cloud()

    static var isConfigured: Bool { !SupabaseSecrets.url.isEmpty && !SupabaseSecrets.secretKey.isEmpty }

    /// The Supabase project this build talks to (shown on Home; not secret).
    static var projectHost: String { URL(string: SupabaseSecrets.url)?.host ?? "none" }

    /// Single user, no login: the secret key (from Codemagic) authorizes everything.
    private static let folder = "offers" // screenshots live in screenshots/offers/

    private let base = SupabaseSecrets.url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()
    private let local = UserDefaults.standard // per-process: queue + status
    private let store = SharedStore.shared
    private var pushTask: Task<Void, Never>?
    private var lastBroadcastPull = Date.distantPast
    private var lastStatePull = Date.distantPast

    // MARK: Status shown on the Home tab

    struct Status { let ok: Bool; let message: String; let at: Date? }

    static func status() -> Status {
        let d = UserDefaults.standard
        guard isConfigured else { return Status(ok: false, message: "Cloud sync not set up in this build", at: nil) }
        let at = d.object(forKey: "cloud.statusAt") as? Date
        return Status(ok: d.bool(forKey: "cloud.ok"), message: d.string(forKey: "cloud.message") ?? "Connecting…", at: at)
    }

    private func setStatus(ok: Bool, _ message: String) {
        local.set(ok, forKey: "cloud.ok")
        local.set(message, forKey: "cloud.message")
        local.set(Date(), forKey: "cloud.statusAt")
    }

    // MARK: Plumbing

    struct CloudError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
            // Postgres can send 6-digit fractions (…:12.123456+00:00); drop the fraction and retry.
            if let dot = s.firstIndex(of: ".") {
                let rest = s[s.index(after: dot)...]
                let tz = rest.drop(while: { $0.isNumber })
                if let date = plain.date(from: String(s[..<dot]) + tz) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    private static let iso = ISO8601DateFormatter()

    @discardableResult
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      contentType: String = "application/json", headers: [String: String] = [:],
                      quiet: Bool = false) async throws -> Data {
        guard Self.isConfigured else { throw CloudError(message: "Cloud sync not set up") }
        guard var comps = URLComponents(string: base + path) else { throw CloudError(message: "Bad URL") }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw CloudError(message: "Bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        let key = SupabaseSecrets.secretKey
        req.setValue(key, forHTTPHeaderField: "apikey")
        if key.hasPrefix("eyJ") { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") } // older-style keys
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Show exactly what Supabase said (never the key), so problems can be diagnosed from the phone.
            var detail = String(decoding: data.prefix(220), as: UTF8.self)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let parts = [obj["code"], obj["error"], obj["message"], obj["msg"], obj["hint"]]
                    .compactMap { $0.map { "\($0)" } }.filter { !$0.isEmpty && $0 != "<null>" }
                if !parts.isEmpty { detail = parts.joined(separator: " · ") }
            }
            if detail.isEmpty { detail = "(no details)" }
            let place = "\(method) \(url.host ?? "?")\(url.path)"
            let msg: String
            switch code {
            case 401, 403: msg = "Key rejected (\(code)) — \(detail) — \(place)"
            default: msg = "Error \(code) — \(detail) — \(place)"
            }
            if !quiet { setStatus(ok: false, msg) } // quiet: an expected "not there yet" isn't a connection problem
            throw CloudError(message: msg)
        }
        if !quiet { setStatus(ok: true, "Connected to Supabase") }
        return data
    }

    // MARK: Rows

    struct OfferRow: Codable {
        var id: UUID
        var date: Date
        var app: String
        var pay: Double
        var miles: Double?
        var minutes: Int?
        var pickup_text: String?
        var dropoff_text: String?
        var grade: String
        var category: String
        var dollars_per_hour: Double?
        var dollars_per_mile: Double?
        var route_note: String?
        var screenshot_path: String?
        var decision: String?   // only the app sends this, so the reader never overwrites your ✓ / ✕
        var pickup_stop: Stop?
        var dropoff_stop: Stop?
        var updated_at: Date?

        init(_ r: OfferRecord, screenshotPath: String?, stops: (pickup: Stop, dropoff: Stop)?) {
            id = r.id; date = r.date; app = r.app.rawValue; pay = r.pay; miles = r.miles; minutes = r.minutes
            pickup_text = r.pickupText; dropoff_text = r.dropoffText; grade = r.grade; category = r.category.rawValue
            dollars_per_hour = r.dollarsPerHour; dollars_per_mile = r.dollarsPerMile; route_note = r.routeNote
            screenshot_path = screenshotPath; decision = nil
            pickup_stop = stops?.pickup; dropoff_stop = stops?.dropoff
            updated_at = r.updatedAt ?? r.date
        }

        var record: OfferRecord {
            OfferRecord(id: id, date: date, app: GigApp(rawValue: app) ?? .unknown, pay: pay, miles: miles,
                        minutes: minutes, pickupText: pickup_text, dropoffText: dropoff_text, grade: grade,
                        category: OfferCategory(rawValue: category) ?? .fair, dollarsPerHour: dollars_per_hour,
                        dollarsPerMile: dollars_per_mile, routeNote: route_note,
                        screenshotFile: screenshot_path.map { ($0 as NSString).lastPathComponent },
                        decision: Decision(rawValue: decision ?? "pending") ?? .pending, updatedAt: updated_at)
                .withLocations(pickup: pickup_stop?.location, dropoff: dropoff_stop?.location,
                               estimated: dropoff_stop.map { $0.label.contains(MapEstimate.label) })
        }
    }

    struct StateRow: Codable {
        var id: String? = "me"
        var settings: DriverSettings?
        var notification_prefs: NotificationPrefs?
        var stops: [Stop]?
        var location: Coord?
        var broadcast_started_at: Date?
        var broadcast_heartbeat: Date?
        var updated_at: Date?
    }

    // MARK: Outbox (queued changes, retried until they reach the cloud)

    private var outbox: [String] {
        get { local.stringArray(forKey: "cloud.outbox") ?? [] }
        set { local.set(Array(newValue.suffix(500)), forKey: "cloud.outbox") }
    }

    private func enqueue(_ item: String) {
        var o = outbox
        if !o.contains(item) { o.append(item) }
        outbox = o
    }

    /// Upload (or refresh) an offer the screen reader logged on this phone.
    func queueOffer(id: UUID, dayKey: String) async {
        enqueue("offer|\(id.uuidString)|\(dayKey)")
        await flush()
    }

    /// Accepted / Declined / pending from the app or a banner button.
    func queueDecision(_ d: Decision, id: UUID) async {
        var o = outbox.filter { !$0.hasPrefix("decision|\(id.uuidString)|") } // newest choice wins
        o.append("decision|\(id.uuidString)|\(d.rawValue)|\(Self.iso.string(from: Date()))")
        outbox = o
        await flush()
    }

    func queueDelete(id: UUID, screenshotFile: String?) async {
        enqueue("delete|\(id.uuidString)|\(screenshotFile ?? "")")
        await flush()
    }

    func flush() async {
        guard Self.isConfigured else { return }
        for item in outbox {
            do {
                let done = try await perform(item)
                if done { outbox = outbox.filter { $0 != item } }
            } catch {
                return // offline or error: keep everything queued and try again later
            }
        }
    }

    private func perform(_ item: String) async throws -> Bool {
        let parts = item.components(separatedBy: "|")
        guard parts.count >= 3, let id = UUID(uuidString: parts[1]) else { return true }
        switch parts[0] {
        case "offer":
            guard let r = OfferLog.shared.record(id: id, dayKey: parts[2]) else { return true }
            var path: String?
            if let file = r.screenshotFile {
                let p = "\(Self.folder)/\(file)"
                var uploaded = Set(local.stringArray(forKey: "cloud.uploadedShots") ?? [])
                if uploaded.contains(file) {
                    path = p
                } else if let jpeg = try? Data(contentsOf: OfferLog.shared.screenshotURL(file)) {
                    try await send("POST", "/storage/v1/object/screenshots/\(p)", body: jpeg,
                                   contentType: "image/jpeg", headers: ["x-upsert": "true"])
                    uploaded.insert(file)
                    local.set(Array(uploaded.suffix(300)), forKey: "cloud.uploadedShots")
                    path = p
                }
            }
            let row = OfferRow(r, screenshotPath: path, stops: store.pendingStops(orderId: id.uuidString))
            try await send("POST", "/rest/v1/offers", query: [URLQueryItem(name: "on_conflict", value: "id")],
                           body: try Self.encoder.encode([row]),
                           headers: ["Prefer": "resolution=merge-duplicates,return=minimal"])
            return true

        case "decision":
            guard parts.count >= 4 else { return true }
            let body = try JSONSerialization.data(withJSONObject: ["decision": parts[2], "updated_at": parts[3]])
            let data = try await send("PATCH", "/rest/v1/offers",
                                      query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")],
                                      body: body, headers: ["Prefer": "return=representation"])
            // If the offer hasn't reached the cloud yet, keep the choice queued and retry later.
            let updated = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
            return updated > 0

        case "delete":
            try await send("DELETE", "/rest/v1/offers", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")])
            let file = parts[2]
            if !file.isEmpty {
                _ = try? await send("DELETE", "/storage/v1/object/screenshots/\(Self.folder)/\(file)")
            }
            return true

        default:
            return true
        }
    }

    // MARK: Offers → app

    /// Downloads offers in a date range and merges them into this phone's log.
    @discardableResult
    func pullOffers(in interval: DateInterval) async -> Bool {
        guard Self.isConfigured else { return false }
        await flush() // send our own changes first so they aren't overwritten
        do {
            let data = try await send("GET", "/rest/v1/offers", query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "date", value: "gte.\(Self.iso.string(from: interval.start))"),
                URLQueryItem(name: "date", value: "lt.\(Self.iso.string(from: interval.end))"),
                URLQueryItem(name: "order", value: "date.asc"),
                URLQueryItem(name: "limit", value: "5000"),
            ])
            let rows = try Self.decoder.decode([OfferRow].self, from: data)
            OfferLog.shared.merge(rows.map(\.record))
            return true
        } catch {
            return false
        }
    }

    /// Pickup + dropoff the screen reader found for an offer (for "Accepted + add to route").
    func stops(for id: UUID) async -> (pickup: Stop, dropoff: Stop)? {
        guard let data = try? await send("GET", "/rest/v1/offers", query: [
            URLQueryItem(name: "select", value: "pickup_stop,dropoff_stop"),
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
        ]) else { return nil }
        struct S: Decodable { let pickup_stop: Stop?; let dropoff_stop: Stop? }
        guard let s = try? Self.decoder.decode([S].self, from: data).first,
              let p = s.pickup_stop, let d = s.dropoff_stop else { return nil }
        return (p, d)
    }

    /// Fetches a screenshot that only exists in the cloud and saves it on this phone.
    func downloadScreenshot(file: String) async -> URL? {
        let dest = OfferLog.shared.screenshotURL(file)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard Self.isConfigured,
              let data = try? await send("GET", "/storage/v1/object/authenticated/screenshots/\(Self.folder)/\(file)")
        else { return nil }
        try? data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: Settings, route, location (app → cloud → screen reader)

    /// Debounced: slider drags send one update, not dozens.
    func schedulePushState() {
        guard Self.isConfigured else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await self.pushStateNow()
        }
    }

    func pushStateNow() async {
        let row = StateRow(id: "me", settings: store.settings, notification_prefs: store.notificationPrefs, stops: store.stops,
                           location: store.currentLocation, broadcast_started_at: nil, broadcast_heartbeat: nil,
                           updated_at: Date())
        _ = try? await upsertState(Self.encoder.encode(row))
    }

    private func upsertState(_ body: Data) async throws {
        try await send("POST", "/rest/v1/app_state", query: [URLQueryItem(name: "on_conflict", value: "id")],
                       body: body, headers: ["Prefer": "resolution=merge-duplicates,return=minimal"])
    }

    private func pullState() async -> StateRow? {
        guard Self.isConfigured,
              let data = try? await send("GET", "/rest/v1/app_state", query: [URLQueryItem(name: "select", value: "*"),
                                                                               URLQueryItem(name: "id", value: "eq.me")]),
              let rows = try? Self.decoder.decode([StateRow].self, from: data) else { return nil }
        return rows.first
    }

    /// Screen reader: load your targets, banner choices, route and location.
    func pullSettingsIntoStore(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastStatePull) > 60 else { return }
        lastStatePull = Date()
        guard let s = await pullState() else { return }
        if let v = s.settings { store.settings = v }
        if let v = s.notification_prefs { store.notificationPrefs = v }
        if let v = s.stops { store.stops = v }
        if let v = s.location { store.currentLocation = v }
    }

    /// App: load the recording timer state written by the screen reader.
    func pullBroadcastIntoStore() async {
        guard Date().timeIntervalSince(lastBroadcastPull) > 8 else { return }
        lastBroadcastPull = Date()
        guard let s = await pullState() else { return }
        if let beat = s.broadcast_heartbeat, beat > (store.broadcastHeartbeat ?? .distantPast) {
            store.broadcastHeartbeat = beat
        }
        store.broadcastStartedAt = s.broadcast_started_at
    }

    // MARK: Missed offers (screen reader → cloud → app), for diagnosing offers that got no banner

    struct MissedRow: Codable, Identifiable {
        var id: UUID
        var date: Date
        var reason: String
        var ocr_text: String
        var screenshot_path: String?
    }

    /// Best effort: if there's no signal, the note is simply dropped (it's only for diagnosis).
    func reportMissed(reason: String, text: String, jpeg: Data?) async {
        guard Self.isConfigured else { return }
        let id = UUID()
        var path: String?
        if let jpeg {
            let p = "missed/\(id.uuidString).jpg"
            if (try? await send("POST", "/storage/v1/object/screenshots/\(p)", body: jpeg,
                                contentType: "image/jpeg", headers: ["x-upsert": "true"])) != nil { path = p }
        }
        let row = MissedRow(id: id, date: Date(), reason: reason, ocr_text: String(text.prefix(4000)), screenshot_path: path)
        _ = try? await send("POST", "/rest/v1/missed_offers", body: try Self.encoder.encode([row]),
                            headers: ["Prefer": "return=minimal"])
    }

    /// Returns the rows, or the exact reason they couldn't be loaded (shown on screen for diagnosis).
    func missedOffersResult(limit: Int = 50) async -> Result<[MissedRow], CloudError> {
        guard Self.isConfigured else {
            return .failure(CloudError(message: "Cloud sync isn't set up in this build. The Supabase variables weren't added in Codemagic (check the supabase group is attached)."))
        }
        let data: Data
        do {
            data = try await send("GET", "/rest/v1/missed_offers", query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "date.desc"),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ])
        } catch let e as CloudError {
            return .failure(e)
        } catch {
            return .failure(CloudError(message: "No connection — \(error.localizedDescription)"))
        }
        do {
            return .success(try Self.decoder.decode([MissedRow].self, from: data))
        } catch {
            let peek = String(decoding: data.prefix(160), as: UTF8.self)
            return .failure(CloudError(message: "Loaded, but couldn't read the rows — \(error) — \(peek)"))
        }
    }

    func missedOffers(limit: Int = 50) async -> [MissedRow]? {
        try? await missedOffersResult(limit: limit).get()
    }

    func deleteMissed(_ row: MissedRow) async {
        _ = try? await send("DELETE", "/rest/v1/missed_offers", query: [URLQueryItem(name: "id", value: "eq.\(row.id.uuidString)")])
        if let p = row.screenshot_path { _ = try? await send("DELETE", "/storage/v1/object/screenshots/\(p)") }
    }

    func missedScreenshot(_ path: String) async -> Data? {
        try? await send("GET", "/storage/v1/object/authenticated/screenshots/\(path)")
    }

    // MARK: Uber Trip Guide (screen reader → cloud → app, for the 👓 button)

    private static let guidePath = "/storage/v1/object/screenshots/state/trip_guide.json"

    func uploadGuide(_ json: Data) async {
        guard Self.isConfigured else { return }
        _ = try? await send("POST", Self.guidePath, body: json, contentType: "application/json",
                            headers: ["x-upsert": "true"])
    }

    func downloadGuide() async -> Data? {
        guard Self.isConfigured else { return nil }
        return try? await send("GET", "/storage/v1/object/authenticated/screenshots/state/trip_guide.json", quiet: true)
    }

    /// The 👓 press (app → screen reader).
    func uploadGuideRequest(_ json: Data) async -> Bool {
        guard Self.isConfigured else { return false }
        return (try? await send("POST", "/storage/v1/object/screenshots/state/guide_request.json", body: json,
                                contentType: "application/json", headers: ["x-upsert": "true"])) != nil
    }

    func downloadGuideRequest() async -> Data? {
        guard Self.isConfigured else { return nil }
        return try? await send("GET", "/storage/v1/object/authenticated/screenshots/state/guide_request.json", quiet: true)
    }


    // MARK: Recording timer (screen reader → cloud → app)

    func broadcastStarted(at date: Date) async {
        let body = try? JSONSerialization.data(withJSONObject: ["id": "me", "broadcast_started_at": Self.iso.string(from: date),
                                                                "broadcast_heartbeat": Self.iso.string(from: date)])
        if let body { try? await upsertState(body) }
    }

    func heartbeat() async {
        let body = try? JSONSerialization.data(withJSONObject: ["id": "me", "broadcast_heartbeat": Self.iso.string(from: Date())])
        if let body { try? await upsertState(body) }
        await flush()
    }

    func broadcastEnded() async {
        let body = try? JSONSerialization.data(withJSONObject: ["id": "me", "broadcast_started_at": NSNull(),
                                                                "broadcast_heartbeat": NSNull()] as [String: Any])
        if let body { try? await upsertState(body) }
    }
}
