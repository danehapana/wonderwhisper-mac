import SwiftUI

struct SettingsModelsView: View {
    @ObservedObject var vm: DictationViewModel

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Voice model", selection: $vm.transcriptionModel) {
                    Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                    Text("whisper-large-v3").tag("whisper-large-v3")
                    Text("distil-whisper-large-v3-en").tag("distil-whisper-large-v3-en")
                    Text("Parakeet v3 (local)").tag("parakeet-local")
                }
            }
            Section("LLM") {
                Toggle("Post-processing with LLM", isOn: $vm.llmEnabled)
                Picker("LLM model", selection: $vm.llmModel) {
                    Text("moonshotai/kimi-k2-instruct").tag("moonshotai/kimi-k2-instruct")
                    Text("openai/gpt-oss-120b").tag("openai/gpt-oss-120b")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
