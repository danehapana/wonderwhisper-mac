import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FluidAudio)
import FluidAudio
#endif

struct SettingsModelsView: View {
    @ObservedObject var vm: DictationViewModel

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Voice model", selection: $vm.transcriptionModel) {
                    Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                    Text("whisper-large-v3").tag("whisper-large-v3")
                    Text("distil-whisper-large-v3-en").tag("distil-whisper-large-v3-en")
                    Text("Groq (Chunked Streaming)").tag("groq-streaming")
                    Text("Parakeet v3 (local)").tag("parakeet-local")
                    Text("AssemblyAI (Streaming)").tag("assemblyai-streaming")
                    Text("Deepgram (Streaming)").tag("deepgram-streaming")
                }
                
                if vm.transcriptionModel == "groq-streaming" {
                    GroupBox("Groq Chunked Streaming") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.yellow)
                                Text("Faster results through intelligent audio chunking")
                                    .font(.subheadline)
                            }
                            Text("• Processes audio in 3-second chunks for faster response times")
                            Text("• Results appear within seconds instead of waiting for full recording")
                            Text("• Ideal for longer recordings and real-time feedback")
                            Text("• Uses whisper-large-v3-turbo for optimal speed/accuracy balance")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    }
                } else if vm.transcriptionModel.lowercased().contains("parakeet") || vm.transcriptionModel.lowercased().contains("local") {
                    GroupBox("Parakeet Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Label(ParakeetManager.isLinked ? "Framework: Linked" : "Framework: Not Linked", systemImage: ParakeetManager.isLinked ? "checkmark.seal" : "xmark.seal")
                                    .foregroundColor(ParakeetManager.isLinked ? .green : .red)
                                Label(ParakeetManager.modelsPresent() ? "Models: Present" : "Models: Missing", systemImage: ParakeetManager.modelsPresent() ? "checkmark.seal" : "xmark.seal")
                                    .foregroundColor(ParakeetManager.modelsPresent() ? .green : .red)
                            }
                            HStack(spacing: 12) {
                                Button("Download/Update Models") { Task { await downloadParakeet() } }
                                    .disabled(!ParakeetManager.isLinked)
                                Button("Show in Finder") { NSWorkspace.shared.selectFile(ParakeetManager.effectiveModelsDirectory.path, inFileViewerRootedAtPath: "") }
                                Button("Remove Models") { try? FileManager.default.removeItem(at: ParakeetManager.effectiveModelsDirectory) }
                                    .disabled(!ParakeetManager.modelsPresent())
                            }
                            Text("Path: \(ParakeetManager.effectiveModelsDirectory.path)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    GroupBox("Parakeet Advanced") {
                        ParakeetAdvancedSettingsView()
                    }
                }
            }
            Section("LLM") {
                Toggle("Post-processing with LLM", isOn: $vm.llmEnabled)
                Picker("LLM model", selection: $vm.llmModel) {
                    Text("moonshotai/kimi-k2-instruct").tag("moonshotai/kimi-k2-instruct")
                    Text("moonshotai/kimi-k2-instruct-0905").tag("moonshotai/kimi-k2-instruct-0905")
                    Text("openai/gpt-oss-120b").tag("openai/gpt-oss-120b")
                    Text("meta-llama/llama-4-scout-17b-16e-instruct").tag("meta-llama/llama-4-scout-17b-16e-instruct")
                }
                Toggle("Streaming (SSE)", isOn: $vm.llmStreaming)
                    .help("Enable streaming responses for faster time-to-first-token. Uses the same prompt and output format.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @MainActor
    private func downloadParakeet() async {
        #if canImport(FluidAudio)
        do {
            try? FileManager.default.createDirectory(at: ParakeetManager.modelsDirectory, withIntermediateDirectories: true)
            _ = try await AsrModels.downloadAndLoad(to: ParakeetManager.modelsDirectory)
        } catch {
            // ignore; UI shows present/missing
        }
        #endif
    }
}
