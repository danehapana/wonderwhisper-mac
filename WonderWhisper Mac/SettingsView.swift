import SwiftUI
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var vm: DictationViewModel

    @State private var apiKeyText: String = ""
    @State private var showAXInfo: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title3)
                .bold()

            GroupBox("Groq API Key") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Enter Groq API Key", text: $apiKeyText)
                    HStack {
                        Button("Save API Key") { vm.saveGroqApiKey(apiKeyText); apiKeyText = "" }
                        Text("Stored in Keychain as \(AppConfig.groqAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Global Hotkey") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use Fn/Globe key to toggle dictation", isOn: $vm.useFnGlobe)
                        .onChange(of: vm.useFnGlobe) { _ in
                            showAXInfo = vm.useFnGlobe && !Self.isAXTrusted()
                        }
                    if showAXInfo {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Accessibility permission required for Fn/Globe detection.")
                                .font(.caption)
                            HStack(spacing: 8) {
                                Button("Open Accessibility Settings") { Self.openAXSettings() }
                                Text("System Settings → Privacy & Security → Accessibility")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Divider()
                    HStack(spacing: 12) {
                        Text("Standard Shortcut:")
                        Button("Use ⌘⌥Space (default)") { vm.setDefaultShortcut() }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Transcription & LLM") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Voice model", selection: $vm.transcriptionModel) {
                        Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                        Text("whisper-large-v3").tag("whisper-large-v3")
                        Text("distil-whisper-large-v3-en").tag("distil-whisper-large-v3-en")
                    }
                    Toggle("Post-processing with LLM", isOn: $vm.llmEnabled)
                    Picker("LLM model", selection: $vm.llmModel) {
                        Text("moonshotai/kimi-k2-instruct").tag("moonshotai/kimi-k2-instruct")
                        Text("openai/gpt-oss-120b").tag("openai/gpt-oss-120b")
                    }
                    Toggle("Use AX direct insertion (faster when supported)", isOn: $vm.useAXInsertion)
                        .help("Requires Accessibility permission. Falls back to paste if not supported.")
                }
            }

            GroupBox("LLM Prompt & Vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Long-form prompt")
                    TextEditor(text: $vm.prompt)
                        .frame(minHeight: 120)
                        .border(Color.gray.opacity(0.2))
                    Text("Custom vocabulary (comma-separated)")
                    TextField("e.g. Groq, Kimi, WonderWhisper", text: $vm.vocabCustom)
                    Text("Spelling rules (from=to per line)")
                    TextEditor(text: $vm.vocabSpelling)
                        .frame(minHeight: 80)
                        .border(Color.gray.opacity(0.2))
                }
            }

            Spacer()
        }
        .padding(16)
        .onAppear {
            // Prompt status if needed
            showAXInfo = vm.useFnGlobe && !Self.isAXTrusted()
        }
    }

    private static func isAXTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

