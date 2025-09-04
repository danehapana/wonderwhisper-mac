import SwiftUI

struct SettingsVocabularyView: View {
  @ObservedObject var vm: DictationViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Custom vocabulary") {
          VStack(alignment: .leading, spacing: 8) {
            Text("One per line or comma-separated")
              .font(.caption)
            TextEditor(text: $vm.vocabCustom)
              .frame(minHeight: 160)
              .border(Color.gray.opacity(0.2))
            Text("Examples:\nGroq\nKimi\nWonderWhisper")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
          .padding(.top, 4)
        }

        GroupBox("Text replacements") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Use one rule per line in the form from=to")
              .font(.caption)
            TextEditor(text: $vm.vocabSpelling)
              .frame(minHeight: 160)
              .border(Color.gray.opacity(0.2))
            Text("Examples: steven=Stephen\nEZY pay=Ezypay")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
          .padding(.top, 4)
        }

        Spacer(minLength: 0)
      }
      .padding(16)
    }
  }
}
