import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var searchText: String = ""
    @State private var selection: HistoryEntry?

    var body: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Start a dictation to see it here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.appName ?? "Unknown App").bold()
                                Spacer()
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.output.isEmpty ? entry.transcript : entry.output)
                                .lineLimit(2)
                                .font(.subheadline)
                        }
                        .contextMenu {
                            Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.output.isEmpty ? entry.transcript : entry.output, forType: .string) }
                            Button("Reveal in Finder") { history.revealInFinder(entry: entry) }
                        }
                    }
                }
                .searchable(text: $searchText)
                .listStyle(.inset)
            }
        }
        .padding([.leading, .trailing], 8)
    }

    private var filtered: [HistoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { e in
            (e.appName?.localizedCaseInsensitiveContains(q) ?? false) ||
            (e.transcript.localizedCaseInsensitiveContains(q)) ||
            (e.output.localizedCaseInsensitiveContains(q))
        }
    }
}

