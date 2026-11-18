import Foundation

/// The Offers log: one JSON file per day plus a Screenshots folder, stored in the shared
/// App Group folder so the screen reader can add offers and the app can mark them.
public final class OfferLog {
    public static let shared = OfferLog(directory: SharedStore.containerURL.appendingPathComponent("OfferLog", isDirectory: true))

    public let directory: URL
    public var screenshotsDirectory: URL { directory.appendingPathComponent("Screenshots", isDirectory: true) }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Screenshots", isDirectory: true),
                                                 withIntermediateDirectories: true)
    }

    // MARK: Day keys

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func fileURL(_ dayKey: String) -> URL { directory.appendingPathComponent("\(dayKey).json") }

    // MARK: Reading

    public func records(dayKey: String) -> [OfferRecord] {
        var result: [OfferRecord] = []
        coordinatedRead(fileURL(dayKey)) { url in
            if let data = try? Data(contentsOf: url), let r = try? self.decoder.decode([OfferRecord].self, from: data) {
                result = r
            }
        }
        return result
    }

    /// All offers whose date falls inside `interval`, oldest first.
    public func records(in interval: DateInterval, calendar: Calendar = .current) -> [OfferRecord] {
        var out: [OfferRecord] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            out += records(dayKey: Self.dayKey(day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out.filter { interval.contains($0.date) && $0.date < interval.end }.sorted { $0.date < $1.date }
    }

    // MARK: Writing

    public func append(_ record: OfferRecord) {
        modify(Self.dayKey(record.date)) { $0.append(record) }
    }

    public func update(id: UUID, dayKey: String, _ change: @escaping (inout OfferRecord) -> Void) {
        modify(dayKey) { list in
            if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
        }
    }

    public func setDecision(_ decision: Decision, id: UUID, dayKey: String) {
        update(id: id, dayKey: dayKey) { $0.decision = decision }
    }

    public func delete(id: UUID, dayKey: String) {
        var shot: String?
        modify(dayKey) { list in
            shot = list.first(where: { $0.id == id })?.screenshotFile
            list.removeAll { $0.id == id }
        }
        if let shot { try? FileManager.default.removeItem(at: screenshotURL(shot)) }
    }

    // MARK: Screenshots

    /// Saves a JPEG and returns its file name (store it in the record).
    public func saveScreenshot(_ jpeg: Data, id: UUID) -> String? {
        let name = "\(id.uuidString).jpg"
        do { try jpeg.write(to: screenshotURL(name), options: .atomic); return name } catch { return nil }
    }

    public func screenshotURL(_ name: String) -> URL { screenshotsDirectory.appendingPathComponent(name) }

    // MARK: File coordination (app and screen reader may write at the same time)

    private func modify(_ dayKey: String, _ change: @escaping (inout [OfferRecord]) -> Void) {
        coordinatedWrite(fileURL(dayKey)) { url in
            var list: [OfferRecord] = []
            if let data = try? Data(contentsOf: url), let r = try? self.decoder.decode([OfferRecord].self, from: data) {
                list = r
            }
            change(&list)
            if let data = try? self.encoder.encode(list) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func coordinatedRead(_ url: URL, _ body: (URL) -> Void) {
        #if canImport(Darwin)
        var err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &err) { body($0) }
        #else
        body(url)
        #endif
    }

    private func coordinatedWrite(_ url: URL, _ body: (URL) -> Void) {
        #if canImport(Darwin)
        var err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &err) { body($0) }
        #else
        body(url)
        #endif
    }
}
