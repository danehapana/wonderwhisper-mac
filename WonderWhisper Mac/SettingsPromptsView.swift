import SwiftUI

struct SettingsPromptsView: View {
    @ObservedObject var vm: DictationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Long-form prompt") {
                    TextEditor(text: $vm.prompt)
                        .frame(minHeight: 160)
                        .border(Color.gray.opacity(0.2))
                        .padding(.top, 4)
                }
                GroupBox("Custom vocabulary") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Words (comma-separated)").font(.caption)
                        TextField("e.g. Groq, Kimi, WonderWhisper", text: $vm.vocabCustom)
                        Text("Spelling rules (from=to per line)").font(.caption)
                        TextEditor(text: $vm.vocabSpelling)
                            .frame(minHeight: 100)
                            .border(Color.gray.opacity(0.2))
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

