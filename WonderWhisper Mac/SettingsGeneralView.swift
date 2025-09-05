import SwiftUI
import ApplicationServices

struct SettingsGeneralView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var apiKeyText: String = ""
    @State private var showAXInfo: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                GroupBox("Insertion") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use AX direct insertion (faster when supported)", isOn: $vm.useAXInsertion)
                            .help("Requires Accessibility permission. Falls back to paste if not supported.")
                        Toggle("Smart in-place formatting (capitalization & end punctuation)", isOn: $vm.smartFormatting)
                            .help("Applies local heuristics using the current text field context to adjust capitalization and sentence-ending punctuation.")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .onAppear { showAXInfo = vm.hotkeySelection.requiresAX && !Self.isAXTrusted() }
    }

    private static func isAXTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
