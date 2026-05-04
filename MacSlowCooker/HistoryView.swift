import SwiftUI
import Observation

@MainActor
@Observable
final class HistoryViewModel {
    private let store: HistoryStore
    private(set) var byGranularity: [HistoryGranularity: [HistoryRecord]] = [:]
    private(set) var nowTs: Int = Int(Date().timeIntervalSince1970)

    init(store: HistoryStore) { self.store = store }

    func reload() {
        nowTs = Int(Date().timeIntervalSince1970)
        var out: [HistoryGranularity: [HistoryRecord]] = [:]
        for g in HistoryGranularity.allCases {
            let since = nowTs - g.retentionSeconds
            out[g] = (try? store.query(granularity: g, sinceTs: since, untilTs: nowTs)) ?? []
        }
        byGranularity = out
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
        .onAppear { model.reload() }
        .task {
            // refresh every 30s while window is open
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.reload()
            }
        }
    }
}
