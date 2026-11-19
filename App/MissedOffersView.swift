import SwiftUI
import GigCore

/// Offers the screen reader saw but couldn't turn into a banner, with what it read and why it gave up.
/// Screenshot a few of these and send them over to get the reading fixed.
struct MissedOffersView: View {
    @State private var rows: [Cloud.MissedRow] = []
    @State private var loading = true
    @State private var failed = false
    @State private var errorText = ""

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else if failed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't load missed offers").font(.subheadline.weight(.semibold))
                    Text(errorText).font(.footnote).textSelection(.enabled)
                    Text("Pull down to try again.").font(.caption).foregroundStyle(.secondary)
                }
            } else if rows.isEmpty {
                Text("Nothing missed yet. When an offer is on screen but GigGrade can't read it, it shows up here with a screenshot and the reason.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
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
        .navigationTitle("Missed offers")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        switch await Cloud.shared.missedOffersResult() {
        case .success(let r): rows = r; failed = false
        case .failure(let e): rows = []; errorText = e.message; failed = true
        }
        loading = false
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
