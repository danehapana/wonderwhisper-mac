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
                    }
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Audio enhancement (beta)", isOn: $vm.audioEnhancementEnabled)
                            .help("Applies a subtle high‑pass filter, pre‑emphasis, and loudness normalization before transcription to improve clarity in noisy/low‑volume conditions.")
                    }
                }

                GroupBox("Network & Transcription") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transcription timeout")
                            Spacer()
                            Stepper(value: $vm.transcriptionTimeoutSeconds, in: 5...120, step: 1) {
                                Text("\(Int(vm.transcriptionTimeoutSeconds))s")
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: 160)
                        }
                        .help("If no response within this time, the request fails and will be retried per network policy.")

                        Toggle("Force HTTP/2 for uploads (experimental)", isOn: $vm.forceHTTP2Uploads)
                            .help("Bypasses HTTP/3/QUIC for multipart uploads to avoid network stalls on some networks.")
                    }
                }

                GroupBox("Screen Context") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Accurate OCR for code editors", isOn: $vm.accurateOCRForEditors)
                            .help("Improves text capture in editors like Cursor/VS Code/Xcode at the cost of a small latency increase (~0.2–0.6s). Turn off to prioritize speed.")
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
