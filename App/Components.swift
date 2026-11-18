import SwiftUI
import AVFoundation
import AudioToolbox
import GigCore

// MARK: - Colors

extension OfferCategory {
    var color: Color {
        switch self {
        case .good: return Color(red: 0.12, green: 0.62, blue: 0.29)
        case .fair: return Color(red: 0.93, green: 0.70, blue: 0.05)
        case .bad: return Color(red: 0.84, green: 0.19, blue: 0.19)
        }
    }
}

extension Notification.Name {
    static let routeChanged = Notification.Name("giggrade.routeChanged")
    static let logChanged = Notification.Name("giggrade.logChanged")
    static let openOffers = Notification.Name("giggrade.openOffers")
}

// MARK: - Double slider

/// Two-handle slider: left of the low handle = bad (red), between = fair (yellow), right of high = good (green).
struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>
    let step: Double

    private let thumb: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let inset = thumb / 2
            let width = max(geo.size.width - thumb, 1)
            let xLow = position(low, width) + inset
            let xHigh = position(high, width) + inset
            let mid = geo.size.height / 2
            ZStack {
                segment(from: inset, to: xLow, color: OfferCategory.bad.color, y: mid)
                segment(from: xLow, to: xHigh, color: OfferCategory.fair.color, y: mid)
                segment(from: xHigh, to: inset + width, color: OfferCategory.good.color, y: mid)
                handle.position(x: xLow, y: mid)
                    .gesture(drag(width: width, inset: inset) { v in low = min(v, high - step) })
                handle.position(x: xHigh, y: mid)
                    .gesture(drag(width: width, inset: inset) { v in high = max(v, low + step) })
            }
            .coordinateSpace(name: "rangeTrack")
        }
        .frame(height: 34)
    }

    private var handle: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .frame(width: thumb, height: thumb)
            .contentShape(Circle().scale(1.6)) // bigger touch target than it looks
    }

    private func segment(from a: CGFloat, to b: CGFloat, color: Color, y: CGFloat) -> some View {
        Capsule().fill(color).frame(width: max(b - a, 0), height: 6).position(x: (a + b) / 2, y: y)
    }

    private func position(_ v: Double, _ width: CGFloat) -> CGFloat {
        let span = bounds.upperBound - bounds.lowerBound
        return CGFloat((min(max(v, bounds.lowerBound), bounds.upperBound) - bounds.lowerBound) / span) * width
    }

    private func drag(width: CGFloat, inset: CGFloat, _ set: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeTrack")).onChanged { g in
            let span = bounds.upperBound - bounds.lowerBound
            let raw = bounds.lowerBound + Double((g.location.x - inset) / width) * span
            let stepped = (raw / step).rounded() * step
            set(min(max(stepped, bounds.lowerBound), bounds.upperBound))
        }
    }
}

/// Title + values + double slider, used for $/hr and $/mi.
struct RangeRow: View {
    let title: String
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("Fair \(String(format: format, low))").foregroundStyle(OfferCategory.fair.color)
                Text("Good \(String(format: format, high))").foregroundStyle(OfferCategory.good.color)
            }
            .font(.subheadline)
            RangeSlider(low: $low, high: $high, bounds: bounds, step: step)
            HStack {
                Text("Bad below \(String(format: format, low))")
                Spacer()
                Text("Good at \(String(format: format, high))+")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Period picker (Day / Week / Month / Quarter / Year)

@MainActor
final class LogModel: ObservableObject {
    @Published var period: Period { didSet { reload(); refreshFromCloud(force: true) } }
    @Published var anchor = Date() { didSet { reload(); refreshFromCloud(force: true) } }
    @Published private(set) var records: [OfferRecord] = []
    @Published private(set) var previous: [OfferRecord] = []

    let calendar = Calendar.current

    init(period: Period) {
        self.period = period
        reload()
    }

    var interval: DateInterval { period.interval(containing: anchor, calendar: calendar) }
    var title: String { period.title(for: interval, calendar: calendar) }
    var canGoForward: Bool { interval.end <= Date() }
    var isCurrent: Bool { interval.contains(Date()) }
    var settings: DriverSettings { SharedStore.shared.settings }

    func move(_ n: Int) { anchor = period.shift(anchor, by: n, calendar: calendar) }

    func reload() {
        let log = OfferLog.shared
        records = log.records(in: interval, calendar: calendar).sorted { $0.date > $1.date }
        let prev = period.interval(containing: period.shift(anchor, by: -1, calendar: calendar), calendar: calendar)
        previous = log.records(in: prev, calendar: calendar)
    }

    struct DayGroup: Identifiable {
        let id: String
        let title: String
        let records: [OfferRecord]
    }

    var days: [DayGroup] {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        let grouped = Dictionary(grouping: records) { OfferLog.dayKey($0.date, calendar: calendar) }
        return grouped.keys.sorted(by: >).map { key in
            let recs = grouped[key] ?? []
            return DayGroup(id: key, title: recs.first.map { f.string(from: $0.date) } ?? key, records: recs)
        }
    }

    func setDecision(_ d: Decision, for r: OfferRecord) {
        let newValue: Decision = r.decision == d ? .pending : d // tap again to undo
        OfferLog.shared.setDecision(newValue, id: r.id, dayKey: OfferLog.dayKey(r.date, calendar: calendar))
        Task { await Cloud.shared.queueDecision(newValue, id: r.id) }
        NotificationCenter.default.post(name: .logChanged, object: nil)
        reload()
    }

    func delete(_ r: OfferRecord) {
        OfferLog.shared.delete(id: r.id, dayKey: OfferLog.dayKey(r.date, calendar: calendar))
        Task { await Cloud.shared.queueDelete(id: r.id, screenshotFile: r.screenshotFile) }
        NotificationCenter.default.post(name: .logChanged, object: nil)
        reload()
    }

    private var lastCloudPull = Date.distantPast
    private var pulling = false

    /// Downloads offers for the visible period (and the one before, for comparisons) from the cloud.
    func refreshFromCloud(force: Bool = false) {
        guard Cloud.isConfigured, !pulling, force || Date().timeIntervalSince(lastCloudPull) > 15 else { return }
        pulling = true
        lastCloudPull = Date()
        let current = interval
        let prev = period.interval(containing: period.shift(anchor, by: -1, calendar: calendar), calendar: calendar)
        Task {
            await Cloud.shared.pullOffers(in: DateInterval(start: prev.start, end: max(current.end, prev.end)))
            self.pulling = false
            self.reload()
        }
    }
}

struct PeriodHeader: View {
    @ObservedObject var model: LogModel

    var body: some View {
        VStack(spacing: 10) {
            Picker("Period", selection: $model.period) {
                ForEach(Period.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button { model.move(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(model.title).font(.headline)
                Spacer()
                Button { model.move(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(!model.canGoForward)
            }
            if !model.isCurrent {
                Button("Jump to today") { model.anchor = Date() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Keeps a tab's data fresh: on appear, when the log changes, and every few seconds.
struct AutoReload: ViewModifier {
    let model: LogModel
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear { model.reload(); model.refreshFromCloud(force: true) }
            .onReceive(tick) { _ in
                model.reload()
                model.refreshFromCloud()
                Task { await Cloud.shared.pullBroadcastIntoStore() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .logChanged)) { _ in model.reload() }
            .onChange(of: phase) { _, p in if p == .active { model.reload(); model.refreshFromCloud(force: true) } }
    }
}

extension View {
    func autoReload(_ model: LogModel) -> some View { modifier(AutoReload(model: model)) }
}

// MARK: - Small pieces

struct AppBadge: View {
    let app: GigApp
    var body: some View {
        Text(app.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).minimumScaleFactor(0.7).lineLimit(1)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }
}

/// How long the screen recording has been on, shown top-right on Home.
struct BroadcastTimer: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let store = SharedStore.shared
            if let start = store.broadcastStartedAt, store.isBroadcasting(now: ctx.date) {
                Label(Self.format(ctx.date.timeIntervalSince(start)), systemImage: "record.circle")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Label("Not recording", systemImage: "record.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(Int(t), 0)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

enum SoundPreview {
    private static var player: AVAudioPlayer?

    static func play(_ choice: SoundChoice) {
        switch choice {
        case .none: return
        case .systemDefault: AudioServicesPlaySystemSound(1007)
        default:
            guard let name = choice.fileName, let url = Bundle.main.url(forResource: name, withExtension: nil) else { return }
            player = try? AVAudioPlayer(contentsOf: url)
            player?.play()
        }
    }
}

func money(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "—" }
