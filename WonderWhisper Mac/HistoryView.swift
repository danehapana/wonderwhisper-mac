import SwiftUI

struct HistoryView: View {
    @ObservedObject var vm: DictationViewModel
    @EnvironmentObject var history: HistoryStore
    @State private var searchText: String = ""
    @State private var selectionID: HistoryEntry.ID?
    @State private var isReprocessing: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(minWidth: 300, maxWidth: 360)
            Divider()
            detailPane
        }
        .onAppear { if selectionID == nil { selectionID = filtered.first?.id } }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            // Controls
            HStack {
                Text("Max entries").font(.caption)
                Spacer()
                Stepper("\(history.maxEntries)", value: $history.maxEntries, in: 10...500, step: 10)
                    .labelsHidden()
            }
            .padding(.vertical, 6)

            if filtered.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Start a dictation to see it here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectionID) {
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
                        .tag(entry.id)
                        .contextMenu {
                            Button("Copy Processed") { copy(entry.output.isEmpty ? entry.transcript : entry.output) }
                            Button("Copy Original") { copy(entry.transcript) }
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

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = selectedEntry {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.appName ?? "Unknown App").bold()
                        if let b = e.bundleID { Text(b).font(.caption).foregroundColor(.secondary) }
                    }
                    Spacer()
                    Button(action: { history.revealInFinder(entry: e) }) { Label("Reveal", systemImage: "folder") }
                }
                HStack(spacing: 12) {
                    if let tm = e.transcriptionModel {
                        Label("Voice: \(tm)", systemImage: "mic").font(.caption)
                    }
                    if let lm = e.llmModel {
                        Label("LLM: \(lm)", systemImage: "brain.head.profile").font(.caption)
                    }
                }
                HStack(spacing: 12) {
                    if let t = e.transcriptionSeconds {
                        Text(String(format: "ASR: %.2fs", t)).font(.caption).foregroundColor(.secondary)
                    }
                    if let l = e.llmSeconds {
                        Text(String(format: "LLM: %.2fs", l)).font(.caption).foregroundColor(.secondary)
                    }
                    if let tot = e.totalSeconds {
                        Text(String(format: "Total: %.2fs", tot)).font(.caption).foregroundColor(.secondary)
                    }
                }
                GroupBox("Processed") {
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView { Text(e.output).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(minHeight: 100)
                        HStack {
                            Button("Copy Processed") { copy(e.output) }
                        }
                    }
                    .padding(6)
                }
                GroupBox("Original Transcript") {
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView { Text(e.transcript).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(minHeight: 100)
                        HStack {
                            Button("Copy Original") { copy(e.transcript) }
                        }
                    }
                    .padding(6)
                }
                if let sc = e.screenContext, !sc.isEmpty {
                    GroupBox("Screen Context") {
                        ScrollView { Text(sc).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(minHeight: 60)
                    }
                }
                if let sel = e.selectedText, !sel.isEmpty {
                    GroupBox("Selected Text") {
                        ScrollView { Text(sel).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(minHeight: 40)
                    }
                }
                HStack {
                    Button {
                        guard !isReprocessing, let sel = selectedEntry else { return }
                        isReprocessing = true
                        Task {
                            await vm.reprocessHistoryEntry(sel)
                            isReprocessing = false
                        }
                    } label: {
                        if isReprocessing { ProgressView().scaleEffect(0.7) } else { Text("Reprocess") }
                    }
                    .disabled(isReprocessing)
                    Spacer()
                }
                Spacer()
            } else {
                ContentUnavailableView("Select an entry", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private var selectedEntry: HistoryEntry? {
        guard let id = selectionID else { return nil }
        return history.entries.first(where: { $0.id == id })
    }
}
