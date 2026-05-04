import SwiftUI
import Observation

@MainActor
@Observable
final class HistoryViewModel {
    private let store: HistoryStore
    private(set) var byGranularity: [HistoryGranularity: [HistoryRecord]] = [:]
    private(set) var nowTs: Int = Int(Date().timeIntervalSince1970)

    init(store: HistoryStore) { self.store = store }

    /// Reload the per-granularity slices off the main thread, then publish to
    /// the view-model on the main actor. Keeps SwiftUI smooth even if SQLite
    /// I/O ever stalls (e.g. heavy disk pressure).
    func reload() async {
        let now = Int(Date().timeIntervalSince1970)
        let store = self.store
        let result: [HistoryGranularity: [HistoryRecord]] = await Task.detached(priority: .userInitiated) {
            var out: [HistoryGranularity: [HistoryRecord]] = [:]
            for g in HistoryGranularity.allCases {
                let since = now - g.retentionSeconds
                out[g] = (try? store.query(granularity: g, sinceTs: since, untilTs: now)) ?? []
            }
            return out
        }.value
        self.nowTs = now
        self.byGranularity = result
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryViewModel
    @State private var selectedPanel: HistoryPanel = .compute

    var body: some View {
        VStack(spacing: 8) {
            Picker("Panel", selection: $selectedPanel) {
                ForEach(HistoryPanel.all) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(HistoryGranularity.allCases, id: \.self) { g in
                        MRTGGraphView(
                            records: model.byGranularity[g] ?? [],
                            panel: selectedPanel,
                            granularity: g,
                            nowTs: model.nowTs
                        )
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 560, minHeight: 860)
        .background(Color(white: 0.82))
        .task {
            await model.reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await model.reload()
            }
        }
    }
}
