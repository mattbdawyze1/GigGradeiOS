import SwiftUI
import GigCore

/// Issues (5.9.6.2): read offers where something went wrong (a verdict that changed after the banner, text and
/// map disagreeing, a store or customer that couldn't be found, a map that couldn't be read…), plus offers the
/// screen reader saw but couldn't read at all (missed offers).
struct MissedOffersView: View {
    @State private var rows: [Cloud.MissedRow] = []
    @State private var briefs: [UUID: Cloud.OfferBrief] = [:]
    @State private var loading = true
    @State private var failed = false
    @State private var errorText = ""
    @AppStorage("issues.notTakenOnly") private var notTakenOnly = true

    private var issues: [Cloud.MissedRow] {
        rows.filter(\.isIssue).filter { !notTakenOnly || decision(of: $0) != "accepted" }
    }
    private var missed: [Cloud.MissedRow] { rows.filter { !$0.isIssue } }

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else if failed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't load issues").font(.subheadline.weight(.semibold))
                    Text(errorText).font(.footnote).textSelection(.enabled)
                    Text("Pull down to try again.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Toggle("Declined / skipped only", isOn: $notTakenOnly)
                } footer: {
                    Text("Skipped = no ✓ or ✕ on the offer.")
                }

                Section("Offer issues") {
                    if issues.isEmpty {
                        Text(notTakenOnly ? "No issues on offers you declined or skipped." : "No issues yet.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(issues) { row in
                        NavigationLink {
                            IssueDetail(row: row, brief: row.offer_id.flatMap { briefs[$0] }) {
                                rows.removeAll { $0.id == row.id }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.reason).font(.subheadline.weight(.semibold)).lineLimit(2)
                                HStack(spacing: 6) {
                                    if let b = row.offer_id.flatMap({ briefs[$0] }) {
                                        Text("\(b.app) · $\(String(format: "%.2f", b.pay))")
                                    }
                                    let d = IssueDetail.decisionLabel(decision(of: row))
                                    Text(d.text).foregroundStyle(d.color)
                                    Text(row.date.formatted(date: .abbreviated, time: .shortened))
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Missed offers") {
                    if missed.isEmpty {
                        Text("Nothing missed yet. When an offer is on screen but GigGrade can't read it, it shows up here with a screenshot and the reason.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(missed) { row in
                        NavigationLink {
                            MissedOfferDetail(row: row) { rows.removeAll { $0.id == row.id } }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.reason).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(row.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Issues")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func decision(of row: Cloud.MissedRow) -> String? {
        row.offer_id.flatMap { briefs[$0]?.decision }
    }

    private func load() async {
        switch await Cloud.shared.missedOffersResult() {
        case .success(let r):
            rows = r; failed = false
            briefs = await Cloud.shared.offerBriefs(r.compactMap(\.offer_id))
        case .failure(let e): rows = []; errorText = e.message; failed = true
        }
        loading = false
    }
}

/// One offer's issues: your decision, what happened (timeline), the offer screenshot, and what was read.
struct IssueDetail: View {
    let row: Cloud.MissedRow
    let brief: Cloud.OfferBrief?
    let onDelete: () -> Void
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    static func decisionLabel(_ d: String?) -> (text: String, color: Color) {
        switch d {
        case "accepted": return ("✓ Accepted", .green)
        case "declined": return ("✕ Declined", .red)
        default: return ("Skipped", .orange)
        }
    }

    var body: some View {
        List {
            Section {
                if let brief {
                    LabeledContent("Offer", value: "\(brief.app) · $\(String(format: "%.2f", brief.pay))")
                }
                let d = Self.decisionLabel(brief?.decision)
                LabeledContent("You") { Text(d.text).foregroundStyle(d.color) }
                LabeledContent("When", value: row.date.formatted(date: .abbreviated, time: .standard))
            }
            Section("What happened") {
                ForEach(Array((row.details ?? row.reason).components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote).textSelection(.enabled)
                }
            }
            Section("Screenshot") {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 520).frame(maxWidth: .infinity)
                } else if row.screenshot_path == nil {
                    Text("No screenshot was saved for this offer.").foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView(); Text("Loading screenshot…").foregroundStyle(.secondary) }
                }
            }
            Section("What the screen reader read") {
                Text(row.ocr_text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
            Section {
                Button("Delete this entry", role: .destructive) {
                    Task { await Cloud.shared.deleteMissed(row); onDelete(); dismiss() }
                }
            } footer: {
                Text("Deletes only this issue entry. The offer and its screenshot stay in your log.")
            }
        }
        .navigationTitle(row.date.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let p = row.screenshot_path, let data = await Cloud.shared.missedScreenshot(p) { image = UIImage(data: data) }
        }
    }
}

struct MissedOfferDetail: View {
    let row: Cloud.MissedRow
    let onDelete: () -> Void
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Why no banner") { Text(row.reason) }
            Section("Screenshot") {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 520).frame(maxWidth: .infinity)
                } else if row.screenshot_path == nil {
                    Text("No screenshot was saved for this one.").foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView(); Text("Loading screenshot…").foregroundStyle(.secondary) }
                }
            }
            Section("What the screen reader read") {
                Text(row.ocr_text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
            Section {
                Button("Delete", role: .destructive) {
                    Task { await Cloud.shared.deleteMissed(row); onDelete(); dismiss() }
                }
            }
        }
        .navigationTitle(row.date.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let p = row.screenshot_path, let data = await Cloud.shared.missedScreenshot(p) { image = UIImage(data: data) }
        }
    }
}
