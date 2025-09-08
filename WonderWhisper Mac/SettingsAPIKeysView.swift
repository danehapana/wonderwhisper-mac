import SwiftUI

struct SettingsAPIKeysView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var groqKeyInput: String = ""
    @State private var assemblyAIKeyInput: String = ""

    var body: some View {
        Form {
            Section("Groq") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Groq API Key", text: $groqKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        Button("Save Groq Key") { vm.saveGroqApiKey(groqKeyInput); groqKeyInput = "" }
                        Text("Stored as \(AppConfig.groqAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("AssemblyAI") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("AssemblyAI API Key", text: $assemblyAIKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        Button("Save AssemblyAI Key") { vm.saveAssemblyAIKey(assemblyAIKeyInput); assemblyAIKeyInput = "" }
                        Text("Stored as \(AppConfig.assemblyAIAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}


