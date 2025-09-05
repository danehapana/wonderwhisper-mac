import SwiftUI

struct SettingsPromptsView: View {
    @ObservedObject var vm: DictationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("System prompt") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $vm.systemPrompt)
                            .frame(minHeight: 220)
                            .border(Color.gray.opacity(0.2))
                        HStack(spacing: 12) {
                            Button("Reset to Default") { vm.systemPrompt = AppConfig.defaultSystemPromptTemplate }
                            Text("Sent as the LLM system role. Placeholder: <VOCABULARY/> auto-fills from settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("User prompt") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $vm.userPrompt)
                            .frame(minHeight: 120)
                            .border(Color.gray.opacity(0.2))
                        HStack(spacing: 12) {
                            Button("Clear") { vm.userPrompt = "" }
                            Text("Appends as an extra user message after transcript context.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}
