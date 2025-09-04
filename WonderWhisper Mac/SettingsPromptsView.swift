import SwiftUI

struct SettingsPromptsView: View {
    @ObservedObject var vm: DictationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Long-form prompt") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $vm.prompt)
                            .frame(minHeight: 220)
                            .border(Color.gray.opacity(0.2))
                        HStack(spacing: 12) {
                            Button("Reset to Default") { vm.prompt = AppConfig.defaultDictationPrompt }
                            Text("Edits apply to all dictations and are sent as the system prompt.")
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
